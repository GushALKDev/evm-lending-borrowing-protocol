// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title Handler
 * @notice Drives the market through bounded random sequences for the invariant suite (Guide 6). A
 *         fixed cast of actors (3 suppliers, 3 borrowers, 1 liquidator, owner, guardian) exercises
 *         every mutating function, plus `warp` (time jumps) and `movePrice` (oracle steps within and
 *         beyond the confidence band). Ghost variables track base inflows/outflows for cash
 *         conservation (INV-5), and latches record per-action violations (the INV-4 reserve table,
 *         INV-9, INV-10, absorb eligibility, unexpected reverts) for the invariant contract to assert.
 * @dev Bounds are chosen so most calls succeed; `fail_on_revert` is off in the suite, so a reverting
 *      call (e.g. an undercollateralized borrow) is a valid no-op, not a failure, provided its reason
 *      is one of the market's own declared errors (see _checkRevert).
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
    // A pure accrue (warp) is asserted separately with a 1-wei tolerance: getReserves() is the
    // difference of two independently-rounded present values, and the index step can wobble it by one
    // wei. Every other action runs at an unchanged timestamp (only warp moves time, and it accrues),
    // so its internal accrue is a no-op and its reserve delta is the conversion alone, which the
    // per-operation table of Guide 2 Section 6 bounds exactly, with no tolerance.
    int256 public reservesBeforeWarp;
    int256 public reservesAfterWarp;
    bool public reserveTableViolated;
    string public reserveTableViolation;

    // --- Latched per-action properties ---
    // fail_on_revert is off, so a require() inside a handler is swallowed as a discarded call, not a
    // failure. Instead each property latches a violation observed right after a successful action,
    // and a global invariant asserts the latch stayed clean.
    bool public inv9Violated;
    bool public inv10Violated;
    bool public absorbedWhileHealthy;
    bool public eligibleButNotAbsorbed;
    bool public unexpectedRevert;
    bytes public unexpectedRevertReason;

    // The market's declared errors: the only acceptable reasons for a handler call to revert. Anything
    // else (a panic, an empty revert, a token error) means an input reached a path it should not.
    mapping(bytes4 => bool) internal expectedError;

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

        bytes4[20] memory errors = [
            ILendingMarket.Paused.selector,
            ILendingMarket.ZeroAmount.selector,
            ILendingMarket.UnknownAsset.selector,
            ILendingMarket.InvalidRecipient.selector,
            ILendingMarket.SupplyCapExceeded.selector,
            ILendingMarket.InsufficientCash.selector,
            ILendingMarket.InsufficientCollateral.selector,
            ILendingMarket.RefundFailed.selector,
            ILendingMarket.NotCollateralized.selector,
            ILendingMarket.MinBorrowNotMet.selector,
            ILendingMarket.NotLiquidatable.selector,
            ILendingMarket.TransferWouldBorrow.selector,
            ILendingMarket.InsufficientAllowance.selector,
            ILendingMarket.NotForSale.selector,
            ILendingMarket.TooMuchSlippage.selector,
            ILendingMarket.InsufficientInventory.selector,
            ILendingMarket.InsufficientReserves.selector,
            ILendingMarket.Unauthorized.selector,
            ILendingMarket.GuardianCannotUnpause.selector,
            ILendingMarket.InvalidConfiguration.selector
        ];
        for (uint256 i = 0; i < errors.length; i++) {
            expectedError[errors[i]] = true;
        }
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

    /// @dev Latches any revert whose selector is not one of the market's declared errors.
    function _checkRevert(bytes memory reason) internal {
        if (reason.length >= 4 && expectedError[bytes4(reason)]) return;
        unexpectedRevert = true;
        unexpectedRevertReason = reason;
    }

    /// @dev Latches a reserve delta outside the Guide 2 Section 6 table for the named operation.
    function _checkReserves(bool holds, string memory op) internal {
        if (holds) return;
        reserveTableViolated = true;
        reserveTableViolation = op;
    }

    /// @dev INV-10 on the acting account: its debt is either closed or at least minBorrow.
    function _checkDust(address account) internal {
        uint256 debt = market.borrowBalanceOf(account);
        if (debt != 0 && debt < market.MIN_BORROW()) inv10Violated = true;
    }

    /*//////////////////////////////////////////////////////////////
                          BASE SUPPLY / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function supplyBase(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e6, 50_000e6); // small enough that borrows can drive utilization past 100%
        base.mint(actor, amount);

        int256 reservesBefore = market.getReserves();
        vm.startPrank(actor);
        base.approve(address(market), amount);
        try market.supply(address(base), amount) {
            ghostBaseIn += amount;
            // Supply and repay: cash in = amount, supply PV credited and debt PV removed round down.
            _checkReserves(market.getReserves() >= reservesBefore, "supplyBase");
        } catch (bytes memory reason) {
            base.burn(actor, amount); // undo the mint on revert to keep the ghost honest
            _checkRevert(reason);
        }
        vm.stopPrank();
    }

    function withdrawBase(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e6, 500_000e6);

        uint256 balBefore = base.balanceOf(actor);
        int256 reservesBefore = market.getReserves();
        vm.prank(actor);
        try market.withdraw(address(base), amount, new bytes[](0)) {
            ghostBaseOut += base.balanceOf(actor) - balBefore;
            // Withdraw and borrow: cash out = amount, supply PV removed and debt PV added round up.
            _checkReserves(market.getReserves() >= reservesBefore, "withdrawBase");
            // INV-9: this is the single borrow entry point, so a success that opened or grew a debt
            // must leave the account collateralized. Latched only on the actor's own successful action
            // (not globally), which is why a later movePrice down-step can still make the account
            // absorb-eligible without tripping this.
            if (!market.isBorrowCollateralized(actor)) inv9Violated = true;
            // INV-10: the only action that creates or grows debt cannot leave it in the dust band.
            _checkDust(actor);
        } catch (bytes memory reason) {
            _checkRevert(reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       COLLATERAL SUPPLY / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function supplyCollateral(uint256 borrowerSeed, uint256 amount) external {
        address actor = _borrower(borrowerSeed);
        amount = bound(amount, 1e15, 100e18);
        weth.mint(actor, amount);

        int256 reservesBefore = market.getReserves();
        vm.startPrank(actor);
        weth.approve(address(market), amount);
        try market.supply(address(weth), amount) {
            // Collateral never touches base cash or base principal.
            _checkReserves(market.getReserves() == reservesBefore, "supplyCollateral");
        } catch (bytes memory reason) {
            weth.burn(actor, amount);
            _checkRevert(reason);
        }
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 borrowerSeed, uint256 amount) external {
        address actor = _borrower(borrowerSeed);
        amount = bound(amount, 1e15, 100e18);
        int256 reservesBefore = market.getReserves();
        vm.prank(actor);
        try market.withdraw(address(weth), amount, new bytes[](0)) {
            _checkReserves(market.getReserves() == reservesBefore, "withdrawCollateral");
            // INV-9: pulling collateral cannot end below the health line for the withdrawing account.
            if (!market.isBorrowCollateralized(actor)) inv9Violated = true;
        } catch (bytes memory reason) {
            _checkRevert(reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER
    //////////////////////////////////////////////////////////////*/

    function transferBase(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, market.balanceOf(from));
        int256 reservesBefore = market.getReserves();
        vm.prank(from);
        try market.transfer(to, amount) {
            // Sender burn rounds up, receiver credit rounds down.
            _checkReserves(market.getReserves() >= reservesBefore, "transferBase");
        } catch (bytes memory reason) {
            _checkRevert(reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION PATHS
    //////////////////////////////////////////////////////////////*/

    function absorb(uint256 borrowerSeed) external {
        address account = _borrower(borrowerSeed);
        // MockPriceOracle's push does not move prices, so the view sees exactly what absorb checks.
        bool eligible = market.isLiquidatable(account);
        int256 reservesBefore = market.getReserves();

        vm.prank(liquidator);
        try market.absorb(account, new bytes[](0)) {
            if (!eligible) absorbedWhileHealthy = true;
            // The only operation designed to spend reserves.
            _checkReserves(market.getReserves() <= reservesBefore, "absorb");
        } catch (bytes memory reason) {
            if (eligible && bytes4(reason) == ILendingMarket.NotLiquidatable.selector) eligibleButNotAbsorbed = true;
            _checkRevert(reason);
        }
    }

    function buyCollateral(uint256 baseAmount) external {
        baseAmount = bound(baseAmount, 1e6, 100_000e6);
        base.mint(liquidator, baseAmount);

        int256 reservesBefore = market.getReserves();
        vm.startPrank(liquidator);
        base.approve(address(market), baseAmount);
        try market.buyCollateral(address(weth), 0, baseAmount, liquidator, new bytes[](0)) {
            ghostBaseIn += baseAmount;
            // Cash in, no base PV change: reserves rise by exactly the base paid.
            _checkReserves(market.getReserves() == reservesBefore + int256(baseAmount), "buyCollateral");
        } catch (bytes memory reason) {
            base.burn(liquidator, baseAmount);
            _checkRevert(reason);
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
            _checkReserves(market.getReserves() == reserves - int256(amount), "withdrawReserves");
        } catch (bytes memory reason) {
            _checkRevert(reason);
        }
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
        try market.setPauseFlags(flags) {}
        catch (bytes memory reason) {
            _checkRevert(reason);
        }
    }
}
