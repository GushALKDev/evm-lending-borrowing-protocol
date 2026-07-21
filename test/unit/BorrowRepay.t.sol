// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {ReentrantPriceOracle} from "../mocks/ReentrantPriceOracle.sol";

/**
 * @title BorrowRepayTest
 * @notice Phase 4 coverage: the negative-principal paths. Borrowing through withdraw(base) past
 *         zero, repaying through supply(base) back across zero, the capacity check against the
 *         mocked oracle, and the minBorrow dust guard.
 * @dev The reference position throughout: 10 WETH at 2,000 USD with an 80% borrow collateral
 *      factor, so capacity is 16,000 USD against a 1 USD base price.
 */
contract BorrowRepayTest is Test {
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

    /// @dev Capacity of the reference position: 10 WETH * 2,000 USD * 80%.
    uint256 internal constant REFERENCE_CAPACITY_USD = 16_000e18;

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

        base.mint(alice, 1_000_000e6);
        base.mint(bob, 1_000_000e6);
        weth.mint(alice, 100e18);

        vm.startPrank(alice);
        base.approve(address(market), type(uint256).max);
        weth.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);

        // Bob is the supply side: every borrow below draws on his cash.
        vm.prank(bob);
        market.supply(address(base), 500_000e6);
    }

    /// @dev Posts the reference collateral position for alice: 10 WETH, 16,000 USD of capacity.
    function _postReferenceCollateral() internal {
        vm.prank(alice);
        market.supply(address(weth), 10e18);
    }

    /// @dev Borrows as alice against the reference position.
    function _borrow(uint256 amount) internal {
        vm.prank(alice);
        market.withdraw(address(base), amount, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                          BORROW PATH (4.1)
    //////////////////////////////////////////////////////////////*/

    function test_borrow_fromZeroOpensDebtAndSendsTokens() public {
        _postReferenceCollateral();

        uint256 balanceBefore = base.balanceOf(alice);
        _borrow(5_000e6);

        assertEq(market.borrowBalanceOf(alice), 5_000e6, "debt opened");
        assertEq(market.balanceOf(alice), 0, "supply balance stays zero");
        assertEq(base.balanceOf(alice), balanceBefore + 5_000e6, "tokens received");
        assertLt(market.getPrincipal(alice), 0, "principal is negative");
    }

    function test_borrow_updatesGlobalTotals() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        assertEq(market.totalBorrow(), 5_000e6, "total borrow tracks the debt");
        // Bob's supply is untouched: borrowing moves cash, not the supply side of the book.
        assertEq(market.totalSupply(), 500_000e6, "total supply unchanged");
    }

    function test_borrow_increasingAnExistingDebtStaysOnOnePath() public {
        _postReferenceCollateral();
        _borrow(5_000e6);
        _borrow(3_000e6);

        assertEq(market.borrowBalanceOf(alice), 8_000e6, "debt accumulated");
        assertEq(market.totalBorrow(), 8_000e6, "totals track the increase");
    }

    /// @dev The sign crossing: a supplier withdrawing past their balance ends up a borrower, with
    ///      the supply side zeroed and the debt equal to the overshoot, in a single call.
    function test_borrow_crossingFromSupplyToDebtInOneWithdrawal() public {
        _postReferenceCollateral();
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        _borrow(3_000e6);

        assertEq(market.balanceOf(alice), 0, "supply side zeroed by the crossing");
        assertEq(market.borrowBalanceOf(alice), 2_000e6, "debt is the overshoot past zero");
    }

    /// @dev INV-1 across a crossing: the totals must equal the sum of principals, split by sign.
    function test_borrow_crossingKeepsTotalsSplitBySign() public {
        _postReferenceCollateral();
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        (uint104 supplyBefore,) = market.getTotals();
        assertEq(supplyBefore, 501_000e6, "alice counted on the supply side");

        _borrow(3_000e6);

        (uint104 supplyAfter, uint104 borrowAfter) = market.getTotals();
        assertEq(supplyAfter, 500_000e6, "alice left the supply total entirely");
        assertEq(borrowAfter, 2_000e6, "and arrived whole on the borrow total");
    }

    function test_borrow_emitsWithdraw() public {
        _postReferenceCollateral();

        vm.expectEmit(true, false, false, true, address(market));
        emit ILendingMarket.Withdraw(alice, 5_000e6);

        _borrow(5_000e6);
    }

    /// @dev A pure borrow burns no supply, so the ERC20 mirror must stay silent.
    function test_borrow_emitsNoTransferWhenNoSupplyIsBurned() public {
        _postReferenceCollateral();

        vm.recordLogs();
        _borrow(5_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(market)) continue;
            assertNotEq(logs[i].topics[0], ILendingMarket.Transfer.selector, "no burn mirror on a pure borrow");
        }
    }

    function test_borrow_revertsWhenCashInsufficient() public {
        _postReferenceCollateral();

        // Bob withdraws the pool down below what alice wants to borrow.
        vm.prank(bob);
        market.withdraw(address(base), 499_000e6, new bytes[](0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InsufficientCash.selector, 5_000e6, 1_000e6));
        market.withdraw(address(base), 5_000e6, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                        CAPACITY CHECK (4.2)
    //////////////////////////////////////////////////////////////*/

    function test_capacity_borrowExactlyAtCapacitySucceeds() public {
        _postReferenceCollateral();

        // 16,000 USD of capacity against a 1 USD base: the boundary is inclusive (debt <= capacity).
        _borrow(16_000e6);

        assertEq(market.borrowBalanceOf(alice), 16_000e6, "borrow at the exact boundary is allowed");
        assertTrue(market.isBorrowCollateralized(alice), "and leaves the account collateralized");
    }

    function test_capacity_borrowOneWeiPastCapacityReverts() public {
        _postReferenceCollateral();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingMarket.NotCollateralized.selector, alice, 16_000e18 + 1e12, REFERENCE_CAPACITY_USD
            )
        );
        market.withdraw(address(base), 16_000e6 + 1, new bytes[](0));
    }

    function test_capacity_confidenceBandShrinksCollateralValue() public {
        _postReferenceCollateral();

        // Collateral is valued at price - conf: a 100 USD band drops capacity to 10 * 1,900 * 0.8.
        oracle.setPrice(address(weth), 2_000e18, 100e18);
        assertEq(_capacityOf(alice), 15_200e18, "capacity uses the low edge of the band");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.NotCollateralized.selector, alice, 15_201e18, 15_200e18));
        market.withdraw(address(base), 15_201e6, new bytes[](0));
    }

    function test_capacity_confidenceBandInflatesDebtValue() public {
        _postReferenceCollateral();
        _borrow(15_000e6);

        // Debt is valued at price + conf: a 10% band on the base makes 15,000 count as 16,500,
        // which exceeds the unchanged 16,000 capacity.
        oracle.setPrice(address(base), 1e18, 0.1e18);

        assertFalse(market.isBorrowCollateralized(alice), "debt valued at the high edge breaks health");
    }

    function test_capacity_isZeroWithoutCollateral() public {
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.NotCollateralized.selector, alice, 500e18, 0));
        market.withdraw(address(base), 1_500e6, new bytes[](0));
    }

    /// @dev Only assets in the account's bitmap count, so unposted collateral grants no capacity.
    function test_capacity_ignoresCollateralNotPosted() public {
        assertEq(_capacityOf(alice), 0, "holding WETH in the wallet is not capacity");

        _postReferenceCollateral();
        assertEq(_capacityOf(alice), REFERENCE_CAPACITY_USD, "posting it is");
    }

    function test_capacity_priceDropCanLeaveAnOpenPositionUncollateralized() public {
        _postReferenceCollateral();
        _borrow(15_000e6);
        assertTrue(market.isBorrowCollateralized(alice), "healthy at 2,000");

        // Capacity falls to 10 * 1,800 * 0.8 = 14,400 < 15,000 of debt.
        oracle.setPrice(address(weth), 1_800e18, 0);

        assertFalse(market.isBorrowCollateralized(alice), "underwater after the drop");
    }

    /// @dev The view and the transactional check must never disagree: both run the same formula.
    function test_capacity_viewAgreesWithTheEnforcedCheck() public {
        _postReferenceCollateral();

        assertTrue(market.isBorrowCollateralized(alice), "no debt is trivially collateralized");

        _borrow(16_000e6);
        assertTrue(market.isBorrowCollateralized(alice), "the view confirms what withdraw allowed");

        // One wei more is refused by withdraw; the view must agree the position is at the edge.
        oracle.setPrice(address(weth), 1_999e18, 0);
        assertFalse(market.isBorrowCollateralized(alice), "and disagrees the moment capacity falls");
    }

    /*//////////////////////////////////////////////////////////////
                        MULTI COLLATERAL CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Capacity sums across every posted asset, each scaled by its own decimals. A second
    ///      collateral with 8 decimals is what would expose a scaling error in the loop: wBTC at
    ///      30,000 USD with a 75% factor contributes 1 * 30,000 * 0.75 = 22,500 on top of WETH's
    ///      16,000, and getting the scale wrong would be off by orders of magnitude, not by dust.
    function test_capacity_sumsAcrossAssetsWithDifferentDecimals() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "wBTC", 8);

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](2);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        collaterals[1] = MarketBuilder.collateral(address(wbtc), 8, 100e8);
        collaterals[1].borrowCollateralFactor = 7500; // 75%, the wBTC reference factor
        collaterals[1].liquidateCollateralFactor = 8000;

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(wbtc), 30_000e18, 0);
        wbtc.mint(alice, 10e8);

        vm.startPrank(alice);
        base.approve(address(market), type(uint256).max);
        weth.approve(address(market), type(uint256).max);
        wbtc.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.prank(bob);
        market.supply(address(base), 500_000e6);

        vm.startPrank(alice);
        market.supply(address(weth), 10e18);
        market.supply(address(wbtc), 1e8);
        vm.stopPrank();

        // 16,000 from WETH + 22,500 from wBTC.
        _borrow(38_500e6);
        assertEq(market.borrowBalanceOf(alice), 38_500e6, "both assets contributed their capacity");

        // One wei past the combined capacity must still be refused.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.NotCollateralized.selector, alice, 38_500e18 + 1e12, 38_500e18)
        );
        market.withdraw(address(base), 1, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                       COLLATERAL WITHDRAWAL HEALTH
    //////////////////////////////////////////////////////////////*/

    function test_withdrawCollateral_revertsWhenItWouldUndercollateralizeTheDebt() public {
        _postReferenceCollateral();
        _borrow(15_000e6);

        // Pulling 2 WETH leaves 8 * 2,000 * 0.8 = 12,800 of capacity against 15,000 of debt.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.NotCollateralized.selector, alice, 15_000e18, 12_800e18));
        market.withdraw(address(weth), 2e18, new bytes[](0));
    }

    function test_withdrawCollateral_allowedWhileTheDebtStaysCovered() public {
        _postReferenceCollateral();
        _borrow(10_000e6);

        // Leaves 8 * 2,000 * 0.8 = 12,800 of capacity against 10,000 of debt.
        vm.prank(alice);
        market.withdraw(address(weth), 2e18, new bytes[](0));

        assertEq(market.userCollateral(alice, address(weth)), 8e18, "collateral released");
        assertTrue(market.isBorrowCollateralized(alice), "position still healthy");
    }

    /*//////////////////////////////////////////////////////////////
                         MIN BORROW GUARD (4.3)
    //////////////////////////////////////////////////////////////*/

    function test_minBorrow_revertsOnADustBorrow() public {
        _postReferenceCollateral();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.MinBorrowNotMet.selector, 1e6, MIN_BORROW));
        market.withdraw(address(base), 1e6, new bytes[](0));
    }

    function test_minBorrow_borrowExactlyAtTheMinimumSucceeds() public {
        _postReferenceCollateral();
        _borrow(MIN_BORROW);

        assertEq(market.borrowBalanceOf(alice), MIN_BORROW, "the bound is inclusive");
    }

    /// @dev The guard is on the resulting debt, not the borrowed amount: a crossing that lands
    ///      between zero and minBorrow is dust just the same, even though nothing was "borrowed".
    function test_minBorrow_revertsWhenACrossingWouldLeaveDust() public {
        _postReferenceCollateral();
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.MinBorrowNotMet.selector, 10e6, MIN_BORROW));
        market.withdraw(address(base), 1_010e6, new bytes[](0));
    }

    /// @dev Dust is only forbidden on the way down. Repaying to exactly zero must stay reachable,
    ///      or a borrower could be trapped above minBorrow with no way to close the position.
    function test_minBorrow_doesNotBlockRepayingToZero() public {
        _postReferenceCollateral();
        _borrow(150e6);

        vm.prank(alice);
        market.supply(address(base), type(uint256).max);

        assertEq(market.borrowBalanceOf(alice), 0, "position closed despite passing through dust");
    }

    /*//////////////////////////////////////////////////////////////
                           REPAY PATH (4.4)
    //////////////////////////////////////////////////////////////*/

    function test_repay_partialReducesDebt() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        vm.prank(alice);
        market.supply(address(base), 2_000e6);

        assertEq(market.borrowBalanceOf(alice), 3_000e6, "debt reduced");
        assertEq(market.balanceOf(alice), 0, "no supply side created");
    }

    function test_repay_exactAmountClosesThePosition() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        vm.prank(alice);
        market.supply(address(base), 5_000e6);

        assertEq(market.borrowBalanceOf(alice), 0, "debt cleared");
        assertEq(market.getPrincipal(alice), 0, "principal back to exactly zero");
    }

    /// @dev Overpaying crosses the sign the other way: the excess becomes a supply balance.
    function test_repay_overpaymentCrossesIntoSupply() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        vm.prank(alice);
        market.supply(address(base), 8_000e6);

        assertEq(market.borrowBalanceOf(alice), 0, "debt cleared");
        assertEq(market.balanceOf(alice), 3_000e6, "excess became supply");
    }

    function test_repay_crossingKeepsTotalsSplitBySign() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        vm.prank(alice);
        market.supply(address(base), 8_000e6);

        (uint104 supplyTotal, uint104 borrowTotal) = market.getTotals();
        assertEq(borrowTotal, 0, "alice left the borrow total entirely");
        assertEq(supplyTotal, 503_000e6, "and arrived whole on the supply total");
    }

    function test_repay_maxSentinelRepaysExactlyTheDebt() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        uint256 walletBefore = base.balanceOf(alice);
        vm.prank(alice);
        market.supply(address(base), type(uint256).max);

        assertEq(market.borrowBalanceOf(alice), 0, "debt cleared");
        assertEq(market.balanceOf(alice), 0, "and nothing supplied beyond it");
        assertEq(walletBefore - base.balanceOf(alice), 5_000e6, "pulled exactly the debt");
    }

    function test_repay_maxSentinelRevertsWithoutDebt() public {
        vm.prank(alice);
        vm.expectRevert(ILendingMarket.ZeroAmount.selector);
        market.supply(address(base), type(uint256).max);
    }

    /// @dev Repaying accrued interest: the sentinel must clear the debt as it stands after accrual,
    ///      not as it stood when the borrow was opened.
    function test_repay_maxSentinelClearsAccruedInterest() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        irm.setRates(1e10, 0);
        vm.warp(block.timestamp + 365 days);
        market.accrue();

        uint256 debt = market.borrowBalanceOf(alice);
        assertGt(debt, 5_000e6, "interest accrued on the debt");

        vm.prank(alice);
        market.supply(address(base), type(uint256).max);

        assertEq(market.borrowBalanceOf(alice), 0, "the grown debt is fully cleared");
    }

    /// @dev Repayment needs no oracle: it can only improve health, so a broken feed must not
    ///      prevent a borrower from getting out of debt.
    function test_repay_worksWithoutAnyPrice() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        // Wipe the feeds: getPrice now reverts for every asset.
        oracle.unsetPrice(address(base));
        oracle.unsetPrice(address(weth));

        vm.prank(alice);
        market.supply(address(base), type(uint256).max);

        assertEq(market.borrowBalanceOf(alice), 0, "repaid with no price available");
    }

    /*//////////////////////////////////////////////////////////////
                        ACCRUE BEFORE ACTION (4.5)
    //////////////////////////////////////////////////////////////*/

    /// @dev Interest compounds on the debt, so a borrower owes more than they took out.
    function test_accrual_growsDebtOverTime() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        irm.setRates(1e10, 0);
        vm.warp(block.timestamp + 365 days);
        market.accrue();

        assertGt(market.borrowBalanceOf(alice), 5_000e6, "debt grew with the borrow index");
    }

    /// @dev The borrow path must accrue before checking capacity, or a borrower could open a
    ///      position against a stale, under-stated debt.
    function test_accrual_borrowAccruesBeforeTheCapacityCheck() public {
        _postReferenceCollateral();
        _borrow(15_000e6);

        irm.setRates(1e10, 0);
        vm.warp(block.timestamp + 365 days);

        // Read against the stale index, exactly what withdraw would see if it skipped accrual:
        // 15,000 of debt, so 1,000 more fits under the 16,000 capacity and the borrow succeeds.
        assertEq(market.borrowBalanceOf(alice), 15_000e6, "stale debt would leave room to borrow");

        // withdraw accrues first, so it values the debt after a year of interest instead, finds the
        // position already past capacity, and refuses. Reaching NotCollateralized (rather than
        // succeeding) is the assertion: only the accrued reading can produce it.
        vm.prank(alice);
        vm.expectPartialRevert(ILendingMarket.NotCollateralized.selector);
        market.withdraw(address(base), 1_000e6, new bytes[](0));

        // And the accrual the reverted call performed is not what made it revert: an explicit
        // accrue leaves the same over-capacity position behind.
        market.accrue();
        assertGt(market.borrowBalanceOf(alice), REFERENCE_CAPACITY_USD / 1e12, "accrued debt exceeds capacity");
    }

    /// @dev Repay must accrue first too, or the sentinel would clear a stale debt and leave the
    ///      interest accrued since the last touch outstanding.
    function test_accrual_repayAccruesBeforeSettling() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        irm.setRates(1e10, 0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        market.supply(address(base), type(uint256).max);

        assertEq(market.borrowBalanceOf(alice), 0, "no interest left behind");
        assertEq(market.getPrincipal(alice), 0, "principal exactly zero");
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE FLAGS
    //////////////////////////////////////////////////////////////*/

    function test_pause_withdrawFlagBlocksBorrowing() public {
        _postReferenceCollateral();

        vm.prank(guardian);
        market.setPauseFlags(1 << 2); // PAUSE_WITHDRAW

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, uint8(1 << 2)));
        market.withdraw(address(base), 5_000e6, new bytes[](0));
    }

    /// @dev Pausing supply also pauses repayment. That is the accepted consequence of the shared
    ///      entry point, recorded here so the coupling is visible rather than discovered later.
    function test_pause_supplyFlagAlsoBlocksRepayment() public {
        _postReferenceCollateral();
        _borrow(5_000e6);

        vm.prank(guardian);
        market.setPauseFlags(1 << 0); // PAUSE_SUPPLY

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, uint8(1 << 0)));
        market.supply(address(base), 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// @dev The borrow path writes the principal, then calls the oracle, then transfers tokens, so
    ///      a hostile oracle gets control while the account's state is already updated but the cash
    ///      has not left. Without the guard it could borrow twice against one capacity check. The
    ///      whole outer call must revert, leaving no debt and no tokens moved.
    function test_reentrancy_hostileOracleCannotBorrowTwice() public {
        ReentrantPriceOracle hostile = new ReentrantPriceOracle();
        hostile.setPrice(address(base), 1e18);
        hostile.setPrice(address(weth), 2_000e18);

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(hostile), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        market = new LendingMarketHarness(cfg, collaterals);

        vm.startPrank(alice);
        base.approve(address(market), type(uint256).max);
        weth.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.prank(bob);
        market.supply(address(base), 500_000e6);

        _postReferenceCollateral();

        hostile.arm(address(market), address(base), 5_000e6);

        uint256 walletBefore = base.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // ReentrancyGuard: reentrant call
        market.withdraw(address(base), 5_000e6, new bytes[](0));

        assertEq(market.borrowBalanceOf(alice), 0, "no debt opened");
        assertEq(base.balanceOf(alice), walletBefore, "no tokens moved");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Capacity in USD, recovered from the revert payload of a borrow that cannot fit. The
    ///      payload is the only place the contract reports capacity as a number, so reading it here
    ///      keeps the expected values in these tests pinned to what the market actually computed.
    function _capacityOf(address account) internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();

        // Borrow far past any plausible capacity so the health check is what refuses it.
        vm.prank(account);
        try market.withdraw(address(base), 400_000e6, new bytes[](0)) {
            fail("expected the borrow to be refused");
            return 0;
        } catch (bytes memory err) {
            vm.revertToState(snapshot);
            assertEq(bytes4(err), ILendingMarket.NotCollateralized.selector, "refused on health");
            (,, uint256 capacityUSD) = abi.decode(_stripSelector(err), (address, uint256, uint256));
            return capacityUSD;
        }
    }

    function _stripSelector(bytes memory err) internal pure returns (bytes memory stripped) {
        stripped = new bytes(err.length - 4);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = err[i + 4];
        }
    }
}
