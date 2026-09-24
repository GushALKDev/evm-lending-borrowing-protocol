// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {Handler} from "./Handler.sol";

/**
 * @title InvariantsTest
 * @notice Phase 8 core: the system invariants from Guide 6, Section 2, asserted after every step of a
 *         bounded random call sequence driven by the Handler. This is the provable-solvency thesis of
 *         the project run as executable stateful fuzzing.
 * @dev fail_on_revert is off (foundry.toml [invariant]): a reverting handler call is a valid no-op
 *      (e.g. an undercollateralized borrow), so only the post-state invariants are load-bearing.
 */
contract InvariantsTest is Test {
    uint64 internal constant BASE_INDEX_SCALE = 1e15;
    uint256 internal constant FACTOR_SCALE = 10_000;
    // Low enough that the borrowers' collateral supplies (up to 100 WETH per call) reach it inside a
    // run, so INV-8 is exercised at the bound instead of holding vacuously.
    uint128 internal constant WETH_SUPPLY_CAP = 500e18;
    // Small against the borrowers' capacity (and supplyBase is bounded to 50k per call), so sequences
    // sweep utilization from zero through the kink to above 100%. At 10M the suite never reached 10%,
    // leaving the jump-rate regime, cash scarcity, and INV-14 unexercised.
    uint256 internal constant SEED_LIQUIDITY = 100_000e6;

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    InterestRateModel internal irm;
    MockPriceOracle internal oracle;
    Handler internal handler;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");

    address[] internal suppliers;
    address[] internal borrowers;
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        // The real derived-rate model: supplyRate = borrowRate * U * (1 - RF), so accrue can never
        // lower reserves (INV-4). Reference curve params (Guide 2, Section 11).
        irm = new InterestRateModel(0, (0.05e18) / uint256(365 days), (1e18) / uint256(365 days), 0.8e18, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        cfg.targetReserves = 100_000_000e6; // high, so buyCollateral stays reachable

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_SUPPLY_CAP);

        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);

        for (uint256 i = 0; i < 3; i++) {
            suppliers.push(makeAddr(string(abi.encodePacked("supplier", i))));
            borrowers.push(makeAddr(string(abi.encodePacked("borrower", i))));
        }

        // Seed initial liquidity so borrows are possible from the first steps.
        address seed = suppliers[0];
        base.mint(seed, SEED_LIQUIDITY);
        vm.startPrank(seed);
        base.approve(address(market), type(uint256).max);
        market.supply(address(base), SEED_LIQUIDITY);
        vm.stopPrank();

        handler = new Handler(market, base, weth, oracle, owner, guardian, suppliers, borrowers, liquidator);

        // Only the handler drives state; target its action functions.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.supplyBase.selector;
        selectors[1] = handler.withdrawBase.selector;
        selectors[2] = handler.supplyCollateral.selector;
        selectors[3] = handler.withdrawCollateral.selector;
        selectors[4] = handler.transferBase.selector;
        selectors[5] = handler.absorb.selector;
        selectors[6] = handler.buyCollateral.selector;
        selectors[7] = handler.withdrawReserves.selector;
        selectors[8] = handler.warp.selector;
        selectors[9] = handler.movePrice.selector;
        selectors[10] = handler.togglePause.selector;
        selectors[11] = handler.supplyBase.selector; // weight supply so the pool stays funded
        selectors[12] = handler.guardianPause.selector;
        selectors[13] = handler.repayWhileSupplyPaused.selector;
        selectors[14] = handler.togglePause.selector; // weight the owner's toggle so guardian flags get cleared
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                        INV-1: PRINCIPAL SUMS (8.2)
    //////////////////////////////////////////////////////////////*/

    /// @dev Exact integer equality: the stored totals equal the summed per-account principal, split by
    ///      sign. The anchor every other accounting property leans on. Sums the seed supplier too.
    function invariant_INV1_principalSumsMatchTotals() public view {
        uint256 sumSupply;
        uint256 sumBorrow;

        // suppliers[0] (the seed supplier) is already in the handler's actor list, so this loop
        // covers every account that can hold principal.
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            (sumSupply, sumBorrow) = _accumulate(handler.actorAt(i), sumSupply, sumBorrow);
        }

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(sumSupply, totalSupplyBase, "INV-1: supply principal sum != totalSupplyBase");
        assertEq(sumBorrow, totalBorrowBase, "INV-1: borrow principal sum != totalBorrowBase");
    }

    function _accumulate(address account, uint256 sumSupply, uint256 sumBorrow)
        internal
        view
        returns (uint256, uint256)
    {
        int104 p = market.getPrincipal(account);
        if (p > 0) sumSupply += uint256(int256(p));
        else if (p < 0) sumBorrow += uint256(int256(-p));
        return (sumSupply, sumBorrow);
    }

    /*//////////////////////////////////////////////////////////////
                        INV-2: INDEX MONOTONICITY (8.3)
    //////////////////////////////////////////////////////////////*/

    /// @dev No ordering between the two indexes is asserted: above U = 1 / (1 - RF) the per-unit supply
    ///      rate exceeds the borrow rate (Guide 2, Section 4), so the supply index can overtake the
    ///      borrow index while suppliers still earn less in total than borrowers pay. The load-bearing
    ///      form of that claim is reserve growth, asserted by the two INV-4 invariants.
    function invariant_INV2_indexesMonotoneAboveSeed() public view {
        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertGe(supplyIndex, BASE_INDEX_SCALE, "INV-2: supply index below seed");
        assertGe(borrowIndex, BASE_INDEX_SCALE, "INV-2: borrow index below seed");
    }

    /*//////////////////////////////////////////////////////////////
                    INV-5: CASH CONSERVATION (8.1)
    //////////////////////////////////////////////////////////////*/

    /// @dev The market's physical base balance equals the ghost-tracked net of every recorded inflow
    ///      and outflow, plus the seed liquidity. No base moves without an accounting entry.
    function invariant_INV5_cashConservation() public view {
        uint256 seeded = SEED_LIQUIDITY;
        uint256 expected = seeded + handler.ghostBaseIn() - handler.ghostBaseOut();
        assertEq(base.balanceOf(address(market)), expected, "INV-5: cash != ghost-tracked net flows");
    }

    /*//////////////////////////////////////////////////////////////
              INV-6/7: COLLATERAL LEDGERS AND BITMAP (8.4)
    //////////////////////////////////////////////////////////////*/

    /// @dev totalsCollateral equals the summed per-user claims (exact), and the physical balance never
    ///      falls below it (the gap is seized inventory plus donations). This is the ADR-7 solvency
    ///      invariant driven across sequences.
    function invariant_INV6_collateralTotalsMatchAndSolvent() public view {
        uint256 sumClaims;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sumClaims += market.userCollateral(handler.actorAt(i), address(weth));
        }

        assertEq(market.totalsCollateral(address(weth)), sumClaims, "INV-6: total != sum of user claims");
        assertGe(
            weth.balanceOf(address(market)),
            market.totalsCollateral(address(weth)),
            "INV-6: physical balance below the total (insolvent)"
        );
    }

    /// @dev A set assetsIn bit iff the account holds a positive collateral balance.
    function invariant_INV7_bitmapMatchesCollateral() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            bool bitSet = market.getAssetsIn(a) & 1 == 1;
            bool hasBalance = market.userCollateral(a, address(weth)) > 0;
            assertEq(bitSet, hasBalance, "INV-7: assetsIn bit disagrees with collateral balance");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INV-11: NO DEBT ON AN EMPTY POOL
    //////////////////////////////////////////////////////////////*/

    function invariant_INV11_noDebtWithoutSupply() public view {
        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        if (totalSupplyBase == 0) {
            assertEq(totalBorrowBase, 0, "INV-11: debt exists against an empty pool");
        }
    }

    /*//////////////////////////////////////////////////////////////
              INV-9: NO ACTION ENDS UNDERCOLLATERALIZED
    //////////////////////////////////////////////////////////////*/

    /// @dev INV-9 is a per-action property, not a global state: a movePrice down-step can legitimately
    ///      make an existing position absorb-eligible with no action at fault, so asserting it globally
    ///      would false-fail on healthy protocol behavior. The handler instead latches a violation only
    ///      when a successful health-reducing action (withdrawBase's borrow branch, withdrawCollateral)
    ///      leaves the acting account below the line. This asserts that latch never tripped.
    function invariant_INV9_noActionLeavesUndercollateralized() public view {
        assertFalse(handler.inv9Violated(), "INV-9: an action left an account undercollateralized");
    }

    /*//////////////////////////////////////////////////////////////
                INV-4: RESERVE MONOTONICITY (per operation)
    //////////////////////////////////////////////////////////////*/

    /// @dev A pure accrue (the warp action) does not lower reserves beyond a 1-wei rounding wobble.
    ///      INV-4 is a directional inequality, not an exact equality (Guide 2, Section 6): the residual
    ///      of borrower interest minus supplier interest accrues to reserves, but getReserves() is read
    ///      as the difference of two independently-rounded present values, so at extreme fuzz states
    ///      that difference can dip by a single wei without any solvency loss. The dip never
    ///      accumulates (verified separately over repeated accruals), so 1 wei is the exact tolerance.
    function invariant_INV4_pureAccrueDoesNotBleedReserves() public view {
        assertGe(handler.reservesAfterWarp() + 1, handler.reservesBeforeWarp(), "INV-4: pure accrue bled reserves");
    }

    /*//////////////////////////////////////////////////////////////
          INV-4: RESERVE TABLE (per operation, Guide 2 Section 6)
    //////////////////////////////////////////////////////////////*/

    /// @dev Every successful action moved reserves in the direction the table allows: supply, repay,
    ///      withdraw, borrow, and transfer never lower them; collateral moves leave them unchanged;
    ///      buyCollateral raises them by exactly the base paid; absorb never raises them; and
    ///      withdrawReserves lowers them by exactly the amount. Exact, no tolerance: see the Handler.
    function invariant_INV4_reserveDeltasMatchTheTable() public view {
        assertFalse(handler.reserveTableViolated(), string.concat("INV-4 table: ", handler.reserveTableViolation()));
    }

    /*//////////////////////////////////////////////////////////////
                INV-3: ROUND TRIPS AT THE LIVE INDEXES
    //////////////////////////////////////////////////////////////*/

    /// @dev The stateless fuzz proves INV-3 at random indexes; this proves it at the indexes the
    ///      sequence actually evolved, on every account's real balance and debt plus fixed probes.
    function invariant_INV3_roundTripsFavorTheProtocolAtLiveIndexes() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            _assertRoundTrips(market.balanceOf(a));
            _assertRoundTrips(market.borrowBalanceOf(a));
        }
        _assertRoundTrips(1);
        _assertRoundTrips(123_456_789);
        _assertRoundTrips(1_000_000e6 + 1);
    }

    function _assertRoundTrips(uint256 pv) internal view {
        uint256 supplyBack = market.exposedPresentValueSupply(market.exposedPrincipalValueSupply(pv));
        assertLe(supplyBack, pv, "INV-3: supply round trip favors the account");
        uint256 debtBack = market.exposedPresentValueBorrow(market.exposedPrincipalValueBorrow(pv));
        assertGe(debtBack, pv, "INV-3: debt round trip favors the account");
    }

    /*//////////////////////////////////////////////////////////////
                        INV-8: SUPPLY CAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Only supply raises totalsCollateral and it is capped at acceptance, while withdraw and
    ///      absorb only lower it, so the per-acceptance bound holds as a global state.
    function invariant_INV8_collateralWithinSupplyCap() public view {
        assertLe(market.totalsCollateral(address(weth)), WETH_SUPPLY_CAP, "INV-8: collateral total above the cap");
    }

    /*//////////////////////////////////////////////////////////////
                      INV-10: NO DUST DEBT CREATED
    //////////////////////////////////////////////////////////////*/

    /// @dev Per-action, like INV-9: the borrow branch of withdraw (the only action that creates or grows
    ///      debt) never leaves the acting account with 0 < debt < minBorrow. Repays and received
    ///      transfers are health-improving and may legally leave a smaller debt (Guide 6, INV-10).
    function invariant_INV10_noActionCreatesDustDebt() public view {
        assertFalse(handler.inv10Violated(), "INV-10: a borrow left debt in the dust band");
    }

    /*//////////////////////////////////////////////////////////////
                    INV-14: SUPPLY RATE BOUNDED BY BORROW RATE
    //////////////////////////////////////////////////////////////*/

    /// @dev The stateless fuzz covers every U in [0, 1e18]; this checks the utilization the sequence
    ///      actually produced, within the same domain. Above U = 1 the market is reachable but the
    ///      per-unit bound is not promised (Guide 2, Section 4): past 1 / (1 - RF) it fails by design.
    function invariant_INV14_supplyRateAtMostBorrowRate() public view {
        uint256 u = market.getUtilization();
        if (u > 1e18) return;
        assertLe(irm.getSupplyRate(u), irm.getBorrowRate(u), "INV-14: supply rate above borrow rate");
    }

    /*//////////////////////////////////////////////////////////////
                  ABSORB ONLY WHEN LIQUIDATABLE (Guide 6)
    //////////////////////////////////////////////////////////////*/

    /// @dev absorb succeeded only on accounts the public view reported liquidatable, and never rejected
    ///      one it reported liquidatable: the view and the check gating the absorb cannot disagree.
    function invariant_absorbOnlyWhenLiquidatable() public view {
        assertFalse(handler.absorbedWhileHealthy(), "absorb succeeded on a healthy account");
        assertFalse(handler.eligibleButNotAbsorbed(), "absorb rejected an account the view reported eligible");
    }

    /*//////////////////////////////////////////////////////////////
                    REPAY STAYS OPEN UNDER PAUSE_SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// @dev While PAUSE_SUPPLY is set, a debtor with tokens and approval can always repay: every repay
    ///      the handler attempted under the pause (partial, exact, or the full-debt sentinel, from the
    ///      debtor or a third party) succeeded.
    function invariant_repayAlwaysAvailableWhileSupplyPaused() public view {
        assertFalse(
            handler.repayBlockedWhilePaused(),
            string.concat("repay refused under PAUSE_SUPPLY: ", vm.toString(handler.repayBlockedReason()))
        );
    }

    /*//////////////////////////////////////////////////////////////
                  NO NEW RISK WHILE PAUSE_BORROW IS SET
    //////////////////////////////////////////////////////////////*/

    /// @dev While PAUSE_BORROW is set, no account's debt grows except through interest accrual, and no
    ///      indebted account's collateral falls except through absorb. Checked around every handler
    ///      action on every actor, not only the one that acted.
    function invariant_noNewRiskWhileBorrowPaused() public view {
        assertFalse(handler.riskAddedWhileBorrowPaused(), handler.riskAddedViolation());
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT-REASON ALLOWLIST
    //////////////////////////////////////////////////////////////*/

    /// @dev fail_on_revert is off, so this is what keeps a panic or a foreign revert from hiding as a
    ///      harmless no-op: every handler revert must carry one of the market's declared errors.
    function invariant_everyRevertIsADeclaredError() public view {
        assertFalse(
            handler.unexpectedRevert(),
            string.concat("undeclared revert reason: ", vm.toString(handler.unexpectedRevertReason()))
        );
    }
}
