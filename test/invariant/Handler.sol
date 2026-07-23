// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title Handler
 * @notice Drives the market through bounded random sequences for the invariant suite (Guide 6). A
 *         fixed cast of actors (3 suppliers, 3 borrowers, 1 liquidator, owner, guardian) exercises
 *         every mutating function, plus `warp` (time jumps) and `movePrice` (oracle steps within and
 *         beyond the confidence band). Ghost variables track base inflows/outflows for cash
 *         conservation (INV-5) and let the invariant contract reason about reserve deltas (INV-4).
 * @dev Bounds are chosen so most calls succeed; `fail_on_revert` is off in the suite, so a reverting
 *      call (e.g. an undercollateralized borrow) is a valid no-op, not a failure.
 */
contract Handler is Test {
    LendingMarketHarness public market;
    MockERC20 public base;
    MockERC20 public weth;
    MockPriceOracle public oracle;
    address public owner;
    address public guardian;

    address[] public suppliers;
    address[] public borrowers;
    address public liquidator;
    address[] public allActors;

    // --- Ghost accounting (INV-5: cash conservation) ---
    uint256 public ghostBaseIn; // every base unit transferred into the market
    uint256 public ghostBaseOut; // every base unit transferred out

    // --- Ghost reserve tracking (INV-4) ---
    // The load-bearing form of INV-4 is that a pure accrue (a warp with no account conversion) never
    // lowers reserves: that is the theorem of the derived-rate model. Other operations run accrue plus
    // a directionally-rounded conversion, whose net effect on getReserves() can wobble by 1 wei
    // without touching solvency, so only warp is asserted here. INV-1 and INV-5 pin the rest exactly.
    int256 public reservesBeforeWarp;
    int256 public reservesAfterWarp;

    // --- Ghost health tracking (INV-9) ---
    // fail_on_revert is off, so a require() inside a handler is swallowed as a discarded call, not a
    // failure. Instead we latch any health violation observed right after a successful health-reducing
    // action and let a global invariant assert the latch stayed clean.
    bool public inv9Violated;

    uint8 internal constant PAUSE_ABSORB = 1 << 3;

    constructor(
        LendingMarketHarness _market,
        MockERC20 _base,
        MockERC20 _weth,
        MockPriceOracle _oracle,
        address _owner,
        address _guardian,
        address[] memory _suppliers,
        address[] memory _borrowers,
        address _liquidator
    ) {
        market = _market;
        base = _base;
        weth = _weth;
        oracle = _oracle;
        owner = _owner;
        guardian = _guardian;
        suppliers = _suppliers;
        borrowers = _borrowers;
        liquidator = _liquidator;

        for (uint256 i = 0; i < _suppliers.length; i++) {
            allActors.push(_suppliers[i]);
        }
        for (uint256 i = 0; i < _borrowers.length; i++) {
            allActors.push(_borrowers[i]);
        }
        allActors.push(_liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function actorsLength() external view returns (uint256) {
        return allActors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return allActors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return allActors[seed % allActors.length];
    }

    function _borrower(uint256 seed) internal view returns (address) {
        return borrowers[seed % borrowers.length];
    }

    /*//////////////////////////////////////////////////////////////
                          BASE SUPPLY / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function supplyBase(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e6, 1_000_000e6);
        base.mint(actor, amount);

        vm.startPrank(actor);
        base.approve(address(market), amount);
        try market.supply(address(base), amount) {
            ghostBaseIn += amount;
        } catch {
            base.burn(actor, amount); // undo the mint on revert to keep the ghost honest
        }
        vm.stopPrank();
    }

    function withdrawBase(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e6, 500_000e6);

        uint256 balBefore = base.balanceOf(actor);
        vm.prank(actor);
        try market.withdraw(address(base), amount, new bytes[](0)) {
            ghostBaseOut += base.balanceOf(actor) - balBefore;
            // INV-9: this is the single borrow entry point, so a success that opened or grew a debt
            // must leave the account collateralized. Latched only on the actor's own successful action
            // (not globally), which is why a later movePrice down-step can still make the account
            // absorb-eligible without tripping this.
            if (!market.isBorrowCollateralized(actor)) inv9Violated = true;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                       COLLATERAL SUPPLY / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function supplyCollateral(uint256 borrowerSeed, uint256 amount) external {
        address actor = _borrower(borrowerSeed);
        amount = bound(amount, 1e15, 100e18);
        weth.mint(actor, amount);

        vm.startPrank(actor);
        weth.approve(address(market), amount);
        try market.supply(address(weth), amount) {}
        catch {
            weth.burn(actor, amount);
        }
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 borrowerSeed, uint256 amount) external {
        address actor = _borrower(borrowerSeed);
        amount = bound(amount, 1e15, 100e18);
        vm.prank(actor);
        try market.withdraw(address(weth), amount, new bytes[](0)) {
            // INV-9: pulling collateral cannot end below the health line for the withdrawing account.
            if (!market.isBorrowCollateralized(actor)) inv9Violated = true;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER
    //////////////////////////////////////////////////////////////*/

    function transferBase(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, market.balanceOf(from));
        vm.prank(from);
        try market.transfer(to, amount) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION PATHS
    //////////////////////////////////////////////////////////////*/

    function absorb(uint256 borrowerSeed) external {
        address account = _borrower(borrowerSeed);
        vm.prank(liquidator);
        try market.absorb(account, new bytes[](0)) {} catch {}
    }

    function buyCollateral(uint256 baseAmount) external {
        baseAmount = bound(baseAmount, 1e6, 100_000e6);
        base.mint(liquidator, baseAmount);

        vm.startPrank(liquidator);
        base.approve(address(market), baseAmount);
        try market.buyCollateral(address(weth), 0, baseAmount, liquidator, new bytes[](0)) {
            ghostBaseIn += baseAmount;
        } catch {
            base.burn(liquidator, baseAmount);
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE / TIME / PRICE
    //////////////////////////////////////////////////////////////*/

    function withdrawReserves(uint256 amount) external {
        int256 reserves = market.getReserves();
        if (reserves <= 0) return;
        amount = bound(amount, 1, uint256(reserves));

        uint256 balBefore = base.balanceOf(owner);
        vm.prank(owner);
        try market.withdrawReserves(owner, amount) {
            ghostBaseOut += base.balanceOf(owner) - balBefore;
        } catch {}
    }

    function warp(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + secondsForward);
        // Snapshot around a pure accrue: the invariant asserts this never lowers reserves.
        reservesBeforeWarp = market.getReserves();
        market.accrue();
        reservesAfterWarp = market.getReserves();
    }

    /// @dev Steps the WETH price up or down, occasionally with a wide confidence band, so absorb
    ///      eligibility and buyCollateral pricing are exercised across regimes.
    function movePrice(uint256 priceRaw, uint256 confRaw) external {
        uint256 price = bound(priceRaw, 100e18, 5_000e18);
        uint256 conf = bound(confRaw, 0, price / 20); // up to 5% band
        oracle.setPrice(address(weth), price, conf);
    }

    function togglePause(uint256 flagsRaw) external {
        uint8 flags = uint8(bound(flagsRaw, 0, 31));
        // Guardian can only add; use the owner so the fuzzer can also clear, exercising both.
        vm.prank(owner);
        try market.setPauseFlags(flags) {} catch {}
    }
}
