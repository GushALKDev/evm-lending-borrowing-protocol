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
 * @title LendingMarketAccountingTest
 * @notice Phase 1 unit coverage: storage layout, conversions, the single accounting path, accrual,
 *         utilization, the rebasing views, and derived reserves.
 */
contract LendingMarketAccountingTest is Test {
    uint64 internal constant BASE_INDEX_SCALE = 1e15;
    uint256 internal constant BASE_SCALE = 1e6;

    // 4% APR expressed per second at 1e18 scale.
    uint256 internal constant RATE_4_PCT = 1268391679;

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockInterestRateModel internal irm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockPriceOracle internal oracle;
    address internal guardian = makeAddr("guardian");

    ILendingMarket.CollateralConfig[] internal noCollateral;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();
        market = new LendingMarketHarness(_config(address(base), address(irm)), noCollateral);
    }

    /// @dev Builds a MarketConfig with the given base and rate model, other fields at test defaults.
    function _config(address baseToken, address interestRateModel)
        internal
        view
        returns (LendingMarket.MarketConfig memory)
    {
        return MarketBuilder.config(baseToken, interestRateModel, address(oracle), address(this), guardian);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTION (1.2)
    //////////////////////////////////////////////////////////////*/

    function test_constructor_seedsBothIndexesAtScale() public view {
        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertEq(supplyIndex, BASE_INDEX_SCALE, "supply index seed");
        assertEq(borrowIndex, BASE_INDEX_SCALE, "borrow index seed");
    }

    function test_constructor_wiresImmutables() public view {
        assertEq(market.BASE_TOKEN(), address(base), "base token");
        assertEq(market.BASE_SCALE(), BASE_SCALE, "base scale");
        assertEq(address(market.INTEREST_RATE_MODEL()), address(irm), "rate model");
        assertEq(address(market.ORACLE()), address(oracle), "oracle");
        assertEq(market.GUARDIAN(), guardian, "guardian");
    }

    function test_constructor_revertsOnZeroBaseToken() public {
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("baseToken")));
        new LendingMarketHarness(_config(address(0), address(irm)), noCollateral);
    }

    function test_constructor_revertsOnZeroRateModel() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("interestRateModel"))
        );
        new LendingMarketHarness(_config(address(base), address(0)), noCollateral);
    }

    /// @dev BASE_SCALE is read from the token, so a wrong literal cannot silently corrupt it.
    function test_constructor_derivesBaseScaleFromTheToken() public {
        MockERC20 eighteenDecimals = new MockERC20("Wrapped Ether", "WETH", 18);
        LendingMarketHarness wethMarket =
            new LendingMarketHarness(_config(address(eighteenDecimals), address(irm)), noCollateral);

        assertEq(wethMarket.BASE_SCALE(), 1e18, "base scale follows the token");
    }

    /// @dev decimals() is optional in the ERC20 standard: a token without it fails deployment.
    function test_constructor_revertsWhenBaseTokenHasNoDecimals() public {
        // The rate model is a non token contract, so it has no decimals() to call.
        vm.expectRevert();
        new LendingMarketHarness(_config(address(irm), address(irm)), noCollateral);
    }

    /*//////////////////////////////////////////////////////////////
                           CONVERSIONS (1.3)
    //////////////////////////////////////////////////////////////*/

    function test_presentValue_isIdentityAtSeedIndexes() public view {
        assertEq(market.exposedPresentValueSupply(10_000e6), 10_000e6, "supply identity");
        assertEq(market.exposedPresentValueBorrow(10_000e6), 10_000e6, "borrow identity");
    }

    /// @dev The worked example from Guide 2, Section 2.
    function test_presentValue_matchesDocumentedWorkedExample() public {
        market.setIndexes(1.05e15, 1.08e15);

        // Supply 10,000 USDC: p = floor(1e10 * 1e15 / 1.05e15).
        uint104 supplyPrincipal = market.exposedPrincipalValueSupply(10_000e6);
        assertEq(supplyPrincipal, 9_523_809_523, "supply principal");

        // Borrow 15,000 USDC: p = -ceil(1.5e10 * 1e15 / 1.08e15).
        uint104 borrowPrincipal = market.exposedPrincipalValueBorrow(15_000e6);
        assertEq(borrowPrincipal, 13_888_888_889, "borrow principal");

        // Reading the debt back owes one unit more than borrowed: rounding favors the protocol.
        assertEq(market.exposedPresentValueBorrow(borrowPrincipal), 15_000_000_001, "debt reads up");
    }

    function test_presentValueSupply_roundsDown() public {
        market.setIndexes(1.05e15, BASE_INDEX_SCALE);
        // 1 * 1.05e15 / 1e15 = 1.05 -> floors to 1.
        assertEq(market.exposedPresentValueSupply(1), 1, "supply PV floors");
    }

    function test_presentValueBorrow_roundsUp() public {
        market.setIndexes(BASE_INDEX_SCALE, 1.05e15);
        // 1 * 1.05e15 / 1e15 = 1.05 -> ceils to 2.
        assertEq(market.exposedPresentValueBorrow(1), 2, "borrow PV ceils");
    }

    function test_principalValueSupply_roundsDown() public {
        market.setIndexes(1.05e15, BASE_INDEX_SCALE);
        // 1 * 1e15 / 1.05e15 = 0.952 -> floors to 0.
        assertEq(market.exposedPrincipalValueSupply(1), 0, "supply principal floors");
    }

    function test_principalValueBorrow_roundsUp() public {
        market.setIndexes(BASE_INDEX_SCALE, 1.05e15);
        // 1 * 1e15 / 1.05e15 = 0.952 -> ceils to 1.
        assertEq(market.exposedPrincipalValueBorrow(1), 1, "borrow principal ceils");
    }

    function test_signedConversions_dispatchOnSign() public {
        market.setIndexes(1.05e15, 1.08e15);

        assertEq(
            market.exposedPresentValue(int104(10_000e6)),
            int256(market.exposedPresentValueSupply(10_000e6)),
            "positive PV"
        );
        assertEq(
            market.exposedPresentValue(-int104(10_000e6)),
            -int256(market.exposedPresentValueBorrow(10_000e6)),
            "negative PV"
        );
        assertEq(market.exposedPresentValue(0), 0, "zero PV");

        assertEq(
            market.exposedPrincipalValue(int256(10_000e6)),
            int104(market.exposedPrincipalValueSupply(10_000e6)),
            "positive p"
        );
        assertEq(
            market.exposedPrincipalValue(-int256(10_000e6)),
            -int104(market.exposedPrincipalValueBorrow(10_000e6)),
            "negative p"
        );
        assertEq(market.exposedPrincipalValue(0), 0, "zero p");
    }

    /*//////////////////////////////////////////////////////////////
                     SINGLE ACCOUNTING PATH (7.4)
    //////////////////////////////////////////////////////////////*/

    function test_accountingPath_creditsSupplyTotal() public {
        market.setPrincipal(alice, int104(1_000e6));

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 1_000e6, "supply total");
        assertEq(totalBorrowBase, 0, "borrow total untouched");
        assertEq(market.getPrincipal(alice), int104(1_000e6), "principal stored");
    }

    function test_accountingPath_creditsBorrowTotal() public {
        market.setPrincipal(alice, -int104(1_000e6));

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 0, "supply total untouched");
        assertEq(totalBorrowBase, 1_000e6, "borrow total");
    }

    /// @dev The crossing that INV-1 is most likely to break on: supply to debt in one write.
    function test_accountingPath_crossesSupplyToBorrow() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(alice, -int104(400e6));

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 0, "supply side zeroed");
        assertEq(totalBorrowBase, 400e6, "borrow side opened");
    }

    function test_accountingPath_crossesBorrowToSupply() public {
        market.setPrincipal(alice, -int104(400e6));
        market.setPrincipal(alice, int104(1_000e6));

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 1_000e6, "supply side opened");
        assertEq(totalBorrowBase, 0, "borrow side zeroed");
    }

    function test_accountingPath_keepsTotalsPerAccountIndependent() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(600e6));

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 1_000e6, "supply total");
        assertEq(totalBorrowBase, 600e6, "borrow total");
    }

    function test_accountingPath_zeroingClearsBothTotals() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(600e6));
        market.setPrincipal(alice, 0);
        market.setPrincipal(bob, 0);

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();
        assertEq(totalSupplyBase, 0, "supply total cleared");
        assertEq(totalBorrowBase, 0, "borrow total cleared");
    }

    /*//////////////////////////////////////////////////////////////
                          UTILIZATION (1.5)
    //////////////////////////////////////////////////////////////*/

    function test_utilization_isZeroOnEmptyMarket() public view {
        assertEq(market.getUtilization(), 0, "empty market");
    }

    function test_utilization_isZeroWhenSupplyIsZero() public {
        // Debt against no supply cannot arise through user actions (INV-11), but the view must
        // still not divide by zero if it is ever reached.
        market.setPrincipal(alice, -int104(1_000e6));
        assertEq(market.getUtilization(), 0, "zero supply guard");
    }

    function test_utilization_halfBorrowed() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(500e6));
        assertEq(market.getUtilization(), 0.5e18, "50 percent");
    }

    /// @dev U > 1e18 is a reachable state once reserves have been paid out (Guide 2, Section 4).
    function test_utilization_canExceedOne() public {
        market.setPrincipal(alice, int104(850_000e6));
        market.setPrincipal(bob, -int104(900_000e6));

        uint256 utilization = market.getUtilization();
        assertGt(utilization, 1e18, "above one");
        assertApproxEqRel(utilization, 1.0588e18, 0.001e18, "matches documented example");
    }

    /*//////////////////////////////////////////////////////////////
                         REBASING VIEWS (1.6)
    //////////////////////////////////////////////////////////////*/

    function test_views_reportOnlyTheMatchingSide() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(600e6));

        assertEq(market.balanceOf(alice), 1_000e6, "supplier balance");
        assertEq(market.borrowBalanceOf(alice), 0, "supplier has no debt");
        assertEq(market.balanceOf(bob), 0, "borrower has no balance");
        assertEq(market.borrowBalanceOf(bob), 600e6, "borrower debt");
    }

    function test_views_totalsTrackPrincipalTotals() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(600e6));

        assertEq(market.totalSupply(), 1_000e6, "total supply");
        assertEq(market.totalBorrow(), 600e6, "total borrow");
    }

    /// @dev The rebasing property: balances grow with the index without any per account write.
    function test_views_balancesRebaseWithIndexes() public {
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(1_000e6));

        market.setIndexes(1.05e15, 1.08e15);

        assertEq(market.balanceOf(alice), 1_050e6, "supply grew 5 percent");
        assertEq(market.borrowBalanceOf(bob), 1_080e6, "debt grew 8 percent");
    }

    /*//////////////////////////////////////////////////////////////
                           RESERVES (1.7)
    //////////////////////////////////////////////////////////////*/

    function test_reserves_areZeroOnEmptyMarket() public view {
        assertEq(market.getReserves(), 0, "empty market");
    }

    function test_reserves_countDonatedCashAsReserves() public {
        base.mint(address(market), 500e6);
        assertEq(market.getReserves(), int256(500e6), "donation is a reserve gift");
    }

    function test_reserves_areDerivedFromCashAndTotals() public {
        // Cash 400, borrows 600, supply 1000 -> reserves 0: the fully lent, unprofitable state.
        base.mint(address(market), 400e6);
        market.setPrincipal(alice, int104(1_000e6));
        market.setPrincipal(bob, -int104(600e6));

        assertEq(market.getReserves(), 0, "derived reserves");
    }

    /// @dev Bad debt is representable: getReserves() is signed on purpose.
    function test_reserves_canBeNegative() public {
        market.setPrincipal(alice, int104(1_000e6));
        assertEq(market.getReserves(), -int256(1_000e6), "negative reserves");
    }

    /*//////////////////////////////////////////////////////////////
                            ACCRUAL (1.4)
    //////////////////////////////////////////////////////////////*/

    function test_accrue_isNoopWithinTheSameBlock() public {
        irm.setRates(RATE_4_PCT, RATE_4_PCT);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertEq(supplyIndex, BASE_INDEX_SCALE, "supply index unchanged");
        assertEq(borrowIndex, BASE_INDEX_SCALE, "borrow index unchanged");
    }

    function test_accrue_advancesBothIndexes() public {
        irm.setRates(RATE_4_PCT, RATE_4_PCT / 2);

        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertGt(borrowIndex, supplyIndex, "borrow outgrows supply");
        // 4% over one year against a 1e15 seed.
        assertApproxEqRel(uint256(borrowIndex), 1.04e15, 0.001e18, "borrow index after a year");
        assertApproxEqRel(uint256(supplyIndex), 1.02e15, 0.001e18, "supply index after a year");
    }

    function test_accrue_updatesLastAccrualTime() public {
        vm.warp(block.timestamp + 1 days);
        market.accrue();
        assertEq(market.getMarketState().lastAccrualTime, uint40(block.timestamp), "timestamp advanced");
    }

    function test_accrue_atZeroRatesLeavesIndexesUntouched() public {
        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertEq(supplyIndex, BASE_INDEX_SCALE, "supply index flat");
        assertEq(borrowIndex, BASE_INDEX_SCALE, "borrow index flat");
    }

    /// @dev Borrow index ceils, so even a sub-wei interest charge advances it.
    function test_accrue_borrowIndexCeilsOnDustInterest() public {
        irm.setRates(1, 1);

        vm.warp(block.timestamp + 1);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertEq(supplyIndex, BASE_INDEX_SCALE, "supply index floors to no change");
        assertEq(borrowIndex, BASE_INDEX_SCALE + 1, "borrow index ceils up");
    }

    function test_accrue_compoundsAcrossWindows() public {
        irm.setRates(RATE_4_PCT, RATE_4_PCT);

        vm.warp(block.timestamp + 182 days);
        market.accrue();
        (, uint64 halfway) = market.getIndexes();

        vm.warp(block.timestamp + 183 days);
        market.accrue();
        (, uint64 full) = market.getIndexes();

        // Compounding: the second window grows the index by more than the first did.
        assertGt(full - halfway, halfway - BASE_INDEX_SCALE, "second window compounds");
    }
}
