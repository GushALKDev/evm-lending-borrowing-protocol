// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title BorrowCapacityFuzzTest
 * @notice Phase 4 properties: whatever the position and the price, a borrow that returns must leave
 *         the account collateralized and above minBorrow, and the capacity formula must round
 *         against the borrower.
 * @dev The postcondition is asserted on the calls that succeed rather than predicting which ones
 *      should: the contract, not the test, decides what fits, and the test checks it never lies.
 */
contract BorrowCapacityFuzzTest is Test {
    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint128 internal constant WETH_CAP = 1_000e18;
    uint256 internal constant MIN_BORROW = 100e6;
    uint256 internal constant BORROW_CF = 8000;
    uint256 internal constant FACTOR_SCALE = 10_000;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);

        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);

        base.mint(bob, 100_000_000e6);
        weth.mint(alice, WETH_CAP);

        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.startPrank(alice);
        base.approve(address(market), type(uint256).max);
        weth.approve(address(market), type(uint256).max);
        vm.stopPrank();

        // Deep supply side so cash never binds before capacity does.
        vm.prank(bob);
        market.supply(address(base), 50_000_000e6);
    }

    /// @dev Any borrow the market accepts must leave the account collateralized. This is the
    ///      postcondition the whole phase exists to guarantee.
    function testFuzz_acceptedBorrowAlwaysLeavesTheAccountCollateralized(
        uint128 collateralAmount,
        uint256 borrowAmount,
        uint256 price
    ) public {
        collateralAmount = uint128(bound(collateralAmount, 1e15, WETH_CAP));
        price = bound(price, 1e18, 100_000e18);
        borrowAmount = bound(borrowAmount, MIN_BORROW, 40_000_000e6);

        oracle.setPrice(address(weth), price, 0);

        vm.prank(alice);
        market.supply(address(weth), collateralAmount);

        vm.prank(alice);
        try market.withdraw(address(base), borrowAmount, new bytes[](0)) {
            assertTrue(market.isBorrowCollateralized(alice), "accepted borrow left the account healthy");
            assertGe(market.borrowBalanceOf(alice), MIN_BORROW, "and above the dust bound");
        } catch {
            // Refusals are the contract's prerogative; this property only constrains acceptances.
        }
    }

    /// @dev A borrow refused on health must be one the capacity formula genuinely cannot cover.
    ///      Pins the boundary from the other side: the market must not refuse what fits.
    function testFuzz_borrowAtOrBelowCapacityIsAccepted(uint128 collateralAmount, uint256 price) public {
        collateralAmount = uint128(bound(collateralAmount, 1e18, WETH_CAP));
        price = bound(price, 100e18, 100_000e18);

        oracle.setPrice(address(weth), price, 0);

        vm.prank(alice);
        market.supply(address(weth), collateralAmount);

        // Capacity in base units: the USD capacity at a 1 USD base price, scaled to 6 decimals.
        uint256 capacityUSD = (uint256(collateralAmount) * BORROW_CF * price) / (1e18 * FACTOR_SCALE);
        uint256 capacityBase = capacityUSD / 1e12;
        // Cash, not capacity, is what would refuse a borrow larger than the pool. Keep the probe
        // inside the pool so the boundary under test stays the capacity check.
        vm.assume(capacityBase >= MIN_BORROW && capacityBase <= base.balanceOf(address(market)));

        vm.prank(alice);
        market.withdraw(address(base), capacityBase, new bytes[](0));

        assertTrue(market.isBorrowCollateralized(alice), "borrowing the full capacity is allowed");
    }

    /// @dev Confidence widens against the borrower on both sides at once: a wider band can only
    ///      lower capacity, never raise it.
    function testFuzz_widerConfidenceNeverIncreasesCapacity(uint128 collateralAmount, uint256 conf) public {
        collateralAmount = uint128(bound(collateralAmount, 1e18, WETH_CAP));
        conf = bound(conf, 0, 1_999e18);

        vm.prank(alice);
        market.supply(address(weth), collateralAmount);

        oracle.setPrice(address(weth), 2_000e18, 0);
        uint256 capacityTight = _maxBorrowable();

        oracle.setPrice(address(weth), 2_000e18, conf);
        uint256 capacityWide = _maxBorrowable();

        assertLe(capacityWide, capacityTight, "confidence never works in the borrower's favor");
    }

    /// @dev Repaying can only improve health, so it must never turn a healthy account unhealthy.
    function testFuzz_repayNeverReducesHealth(uint128 collateralAmount, uint256 borrowAmount, uint256 repayAmount)
        public
    {
        collateralAmount = uint128(bound(collateralAmount, 1e18, WETH_CAP));
        oracle.setPrice(address(weth), 2_000e18, 0);

        vm.prank(alice);
        market.supply(address(weth), collateralAmount);

        uint256 capacityBase = (uint256(collateralAmount) * BORROW_CF * 2_000) / FACTOR_SCALE / 1e12;
        vm.assume(capacityBase >= MIN_BORROW);
        borrowAmount = bound(borrowAmount, MIN_BORROW, capacityBase);

        vm.prank(alice);
        market.withdraw(address(base), borrowAmount, new bytes[](0));

        base.mint(alice, borrowAmount);
        repayAmount = bound(repayAmount, 1, borrowAmount);

        vm.prank(alice);
        market.supply(address(base), repayAmount);

        assertTrue(market.isBorrowCollateralized(alice), "repay left the account collateralized");
        assertLe(market.borrowBalanceOf(alice), borrowAmount, "and never increased the debt");
    }

    /// @dev The sign crossing is exact in both directions: borrowing past a supply balance and then
    ///      repaying the same amount returns the account to its starting principal, never better.
    function testFuzz_crossingRoundTripNeverFavorsTheAccount(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, MIN_BORROW, 100_000e6);
        // Withdraw past the supply so the position crosses into debt, landing above the dust bound.
        withdrawAmount = bound(withdrawAmount, supplyAmount + MIN_BORROW, supplyAmount + 100_000e6);

        oracle.setPrice(address(weth), 2_000e18, 0);
        vm.prank(alice);
        market.supply(address(weth), WETH_CAP);

        base.mint(alice, supplyAmount + withdrawAmount);

        vm.prank(alice);
        market.supply(address(base), supplyAmount);
        vm.prank(alice);
        market.withdraw(address(base), withdrawAmount, new bytes[](0));

        assertEq(market.balanceOf(alice), 0, "the crossing zeroed the supply side");
        assertEq(market.borrowBalanceOf(alice), withdrawAmount - supplyAmount, "debt is exactly the overshoot");

        // Repay the way back across zero.
        vm.prank(alice);
        market.supply(address(base), withdrawAmount);

        assertEq(market.borrowBalanceOf(alice), 0, "debt cleared");
        // At a flat index the round trip is exact; rounding may only ever cost the account.
        assertLe(market.balanceOf(alice), supplyAmount, "the round trip never pays the account");
    }

    /// @dev No accepted borrow may leave a debt in the forbidden dust band.
    function testFuzz_acceptedBorrowNeverLandsInTheDustBand(uint128 collateralAmount, uint256 borrowAmount) public {
        collateralAmount = uint128(bound(collateralAmount, 1e18, WETH_CAP));
        borrowAmount = bound(borrowAmount, 1, 200e6);

        oracle.setPrice(address(weth), 2_000e18, 0);
        vm.prank(alice);
        market.supply(address(weth), collateralAmount);

        vm.prank(alice);
        try market.withdraw(address(base), borrowAmount, new bytes[](0)) {
            uint256 debt = market.borrowBalanceOf(alice);
            assertTrue(debt == 0 || debt >= MIN_BORROW, "debt is either closed or above the dust bound");
        } catch {
            // Dust borrows are expected to be refused.
        }
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Largest borrow the market currently accepts for alice, by binary search on the real
    ///      contract. Reverting to a snapshot each probe keeps the search side-effect free.
    function _maxBorrowable() internal returns (uint256) {
        uint256 low = 0;
        uint256 high = 40_000_000e6;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            uint256 snapshot = vm.snapshotState();

            vm.prank(alice);
            try market.withdraw(address(base), mid, new bytes[](0)) {
                low = mid;
            } catch {
                high = mid - 1;
            }
            vm.revertToState(snapshot);
        }
        return low;
    }
}
