// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";

/**
 * @title ConversionRoundingTest
 * @notice Phase 1 fuzz coverage for INV-2 and INV-3: conversion round trips never favor the
 *         account, and indexes only ever grow.
 * @dev These are the tests the solvency thesis rests on. Every assertion pins a rounding
 *      direction, never a dust magnitude (Guide 2, Section 10).
 */
contract ConversionRoundingTest is Test {
    uint64 internal constant BASE_INDEX_SCALE = 1e15;

    /// @dev Indexes only grow, and uint64 at 1e15 bounds growth to ~18,446x.
    uint64 internal constant MAX_INDEX = type(uint64).max;

    /// @dev int104 bounds the principal domain (~1e25 USDC at 6 decimals).
    uint104 internal constant MAX_PRINCIPAL = uint104(type(int104).max);

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockInterestRateModel internal irm;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        market = new LendingMarketHarness(address(base), address(irm));
    }

    /*//////////////////////////////////////////////////////////////
                    INV-3: ROUND TRIPS FAVOR THE PROTOCOL
    //////////////////////////////////////////////////////////////*/

    /// @notice presentValue(principalValue(pv)) <= pv: a supplier never gains from a round trip.
    function testFuzz_supplyRoundTrip_neverFavorsTheSupplier(uint256 pv, uint64 supplyIndex) public {
        supplyIndex = uint64(bound(supplyIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(supplyIndex, BASE_INDEX_SCALE);

        // Bound the present value so the derived principal stays inside int104.
        pv = bound(pv, 0, uint256(MAX_PRINCIPAL) / 1e4);

        uint104 principal = market.exposedPrincipalValueSupply(pv);
        uint256 roundTripped = market.exposedPresentValueSupply(principal);

        assertLe(roundTripped, pv, "supplier gained on a round trip");
    }

    /// @notice |presentValue(principalValue(pv))| >= |pv|: a borrower never owes less.
    function testFuzz_borrowRoundTrip_neverFavorsTheBorrower(uint256 pv, uint64 borrowIndex) public {
        borrowIndex = uint64(bound(borrowIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(BASE_INDEX_SCALE, borrowIndex);

        pv = bound(pv, 0, uint256(MAX_PRINCIPAL) / 1e4);

        uint104 principal = market.exposedPrincipalValueBorrow(pv);
        uint256 roundTripped = market.exposedPresentValueBorrow(principal);

        assertGe(roundTripped, pv, "borrower owed less after a round trip");
    }

    /// @notice The reverse round trip must hold too: principal -> PV -> principal.
    function testFuzz_supplyPrincipalRoundTrip_neverGrows(uint104 principal, uint64 supplyIndex) public {
        supplyIndex = uint64(bound(supplyIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(supplyIndex, BASE_INDEX_SCALE);

        principal = uint104(bound(principal, 0, MAX_PRINCIPAL / 1e4));

        uint256 pv = market.exposedPresentValueSupply(principal);
        uint104 roundTripped = market.exposedPrincipalValueSupply(pv);

        assertLe(roundTripped, principal, "supply principal grew on a round trip");
    }

    function testFuzz_borrowPrincipalRoundTrip_neverShrinks(uint104 principal, uint64 borrowIndex) public {
        borrowIndex = uint64(bound(borrowIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(BASE_INDEX_SCALE, borrowIndex);

        principal = uint104(bound(principal, 0, MAX_PRINCIPAL / 1e4));

        uint256 pv = market.exposedPresentValueBorrow(principal);
        uint104 roundTripped = market.exposedPrincipalValueBorrow(pv);

        assertGe(roundTripped, principal, "debt principal shrank on a round trip");
    }

    /*//////////////////////////////////////////////////////////////
                      DIRECTED ROUNDING PER SITE
    //////////////////////////////////////////////////////////////*/

    // Round trips alone are too weak to pin every site: flipping presentValueSupply to round up
    // partially cancels against principalValueSupply's floor and can survive a round trip
    // assertion. These four tests pin each division against its exact expected value instead, so
    // any single flipped rounding direction fails the suite (Guide 6, Section 7 mutation checks).

    /// @notice presentValueSupply floors: it must equal the exact quotient truncated.
    function testFuzz_presentValueSupply_floorsExactly(uint104 principal, uint64 supplyIndex) public {
        supplyIndex = uint64(bound(supplyIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(supplyIndex, BASE_INDEX_SCALE);
        principal = uint104(bound(principal, 0, MAX_PRINCIPAL / 1e4));

        uint256 exact = (uint256(principal) * supplyIndex) / BASE_INDEX_SCALE;
        assertEq(market.exposedPresentValueSupply(principal), exact, "supply PV did not floor");
    }

    /// @notice presentValueBorrow ceils: it must equal the exact quotient rounded away from zero.
    function testFuzz_presentValueBorrow_ceilsExactly(uint104 principal, uint64 borrowIndex) public {
        borrowIndex = uint64(bound(borrowIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(BASE_INDEX_SCALE, borrowIndex);
        principal = uint104(bound(principal, 0, MAX_PRINCIPAL / 1e4));

        uint256 numerator = uint256(principal) * borrowIndex;
        uint256 exact = (numerator + BASE_INDEX_SCALE - 1) / BASE_INDEX_SCALE;
        assertEq(market.exposedPresentValueBorrow(principal), exact, "debt PV did not ceil");
    }

    /// @notice principalValueSupply floors.
    function testFuzz_principalValueSupply_floorsExactly(uint256 pv, uint64 supplyIndex) public {
        supplyIndex = uint64(bound(supplyIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(supplyIndex, BASE_INDEX_SCALE);
        pv = bound(pv, 0, uint256(MAX_PRINCIPAL) / 1e4);

        uint256 exact = (pv * BASE_INDEX_SCALE) / supplyIndex;
        assertEq(market.exposedPrincipalValueSupply(pv), exact, "supply principal did not floor");
    }

    /// @notice principalValueBorrow ceils.
    function testFuzz_principalValueBorrow_ceilsExactly(uint256 pv, uint64 borrowIndex) public {
        borrowIndex = uint64(bound(borrowIndex, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(BASE_INDEX_SCALE, borrowIndex);
        pv = bound(pv, 0, uint256(MAX_PRINCIPAL) / 1e4);

        uint256 numerator = pv * BASE_INDEX_SCALE;
        uint256 exact = (numerator + borrowIndex - 1) / borrowIndex;
        assertEq(market.exposedPrincipalValueBorrow(pv), exact, "debt principal did not ceil");
    }

    /// @notice The borrow side is always valued at least as high as the supply side at equal indexes.
    function testFuzz_borrowSideNeverValuedBelowSupplySide(uint104 principal, uint64 index) public {
        index = uint64(bound(index, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(index, index);

        principal = uint104(bound(principal, 0, MAX_PRINCIPAL / 1e4));

        assertGe(
            market.exposedPresentValueBorrow(principal),
            market.exposedPresentValueSupply(principal),
            "debt valued below supply at equal indexes"
        );
    }

    /// @notice Debt principal is always recorded at least as large as supply principal would be.
    function testFuzz_debtPrincipalNeverBelowSupplyPrincipal(uint256 pv, uint64 index) public {
        index = uint64(bound(index, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(index, index);

        pv = bound(pv, 0, uint256(MAX_PRINCIPAL) / 1e4);

        assertGe(
            market.exposedPrincipalValueBorrow(pv),
            market.exposedPrincipalValueSupply(pv),
            "debt principal recorded below supply principal"
        );
    }

    /// @notice Conversions are monotone: more present value never yields less principal.
    function testFuzz_conversionsAreMonotone(uint256 pvLow, uint256 pvHigh, uint64 index) public {
        index = uint64(bound(index, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(index, index);

        pvLow = bound(pvLow, 0, uint256(MAX_PRINCIPAL) / 1e4);
        pvHigh = bound(pvHigh, pvLow, uint256(MAX_PRINCIPAL) / 1e4);

        assertLe(
            market.exposedPrincipalValueSupply(pvLow), market.exposedPrincipalValueSupply(pvHigh), "supply not monotone"
        );
        assertLe(
            market.exposedPrincipalValueBorrow(pvLow), market.exposedPrincipalValueBorrow(pvHigh), "borrow not monotone"
        );
    }

    /// @notice The signed wrappers must agree with the unsigned primitives on both branches.
    function testFuzz_signedConversionsMatchPrimitives(int104 principal, uint64 supplyIdx, uint64 borrowIdx) public {
        supplyIdx = uint64(bound(supplyIdx, BASE_INDEX_SCALE, MAX_INDEX));
        borrowIdx = uint64(bound(borrowIdx, BASE_INDEX_SCALE, MAX_INDEX));
        market.setIndexes(supplyIdx, borrowIdx);

        principal = int104(
            bound(int256(principal), -int256(uint256(MAX_PRINCIPAL / 1e4)), int256(uint256(MAX_PRINCIPAL / 1e4)))
        );

        int256 signedPV = market.exposedPresentValue(principal);

        if (principal >= 0) {
            assertEq(signedPV, int256(market.exposedPresentValueSupply(uint104(principal))), "supply branch");
            assertGe(signedPV, 0, "supply PV sign");
        } else {
            assertEq(
                signedPV, -int256(market.exposedPresentValueBorrow(uint104(magnitude(principal)))), "borrow branch"
            );
            assertLe(signedPV, 0, "debt PV sign");
        }
    }

    /// @notice Utilization floors, which is the direction Guide 2, Section 6 proves reserve safe.
    function testFuzz_utilization_floorsExactly(uint104 supplyPrincipal, uint104 borrowPrincipal) public {
        supplyPrincipal = uint104(bound(supplyPrincipal, 1, MAX_PRINCIPAL / 1e6));
        borrowPrincipal = uint104(bound(borrowPrincipal, 0, MAX_PRINCIPAL / 1e6));

        market.setPrincipal(address(0xA), int104(supplyPrincipal));
        market.setPrincipal(address(0xB), -int104(borrowPrincipal));

        uint256 supplyPV = market.exposedPresentValueSupply(supplyPrincipal);
        uint256 borrowPV = market.exposedPresentValueBorrow(borrowPrincipal);

        uint256 expected = supplyPV == 0 ? 0 : (borrowPV * 1e18) / supplyPV;
        assertEq(market.getUtilization(), expected, "utilization did not floor");
    }

    /*//////////////////////////////////////////////////////////////
                       INV-2: INDEX MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Indexes never decrease and never fall below the seed, over arbitrary time gaps.
    function testFuzz_accrual_indexesAreMonotone(uint256 borrowRate, uint256 supplyRate, uint32 elapsed) public {
        // Bound rates well below 100% per second: the realistic domain, and enough headroom that a
        // multi-year warp cannot overflow uint64.
        borrowRate = bound(borrowRate, 0, 1e12);
        supplyRate = bound(supplyRate, 0, borrowRate);
        elapsed = uint32(bound(elapsed, 0, 365 days));

        irm.setRates(borrowRate, supplyRate);

        (uint64 supplyBefore, uint64 borrowBefore) = market.getIndexes();

        vm.warp(block.timestamp + elapsed);
        market.accrue();

        (uint64 supplyAfter, uint64 borrowAfter) = market.getIndexes();

        assertGe(supplyAfter, supplyBefore, "supply index decreased");
        assertGe(borrowAfter, borrowBefore, "borrow index decreased");
        assertGe(supplyAfter, BASE_INDEX_SCALE, "supply index below seed");
        assertGe(borrowAfter, BASE_INDEX_SCALE, "borrow index below seed");
    }

    /// @notice With supplyRate <= borrowRate, the borrow index outgrows the supply index forever.
    function testFuzz_accrual_borrowIndexOutgrowsSupplyIndex(uint256 borrowRate, uint32 elapsed) public {
        borrowRate = bound(borrowRate, 1, 1e12);
        uint256 supplyRate = borrowRate / 2;
        elapsed = uint32(bound(elapsed, 1, 365 days));

        irm.setRates(borrowRate, supplyRate);

        vm.warp(block.timestamp + elapsed);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertGe(borrowIndex, supplyIndex, "supply index overtook borrow index");
    }

    /// @notice The supply index floors and the borrow index ceils on every accrual.
    function testFuzz_accrual_indexRoundingIsDirected(uint256 rate, uint32 elapsed) public {
        rate = bound(rate, 1, 1e12);
        elapsed = uint32(bound(elapsed, 1, 365 days));

        irm.setRates(rate, rate);

        vm.warp(block.timestamp + elapsed);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();

        uint256 numerator = uint256(BASE_INDEX_SCALE) * (rate * elapsed);
        uint256 expectedSupply = BASE_INDEX_SCALE + numerator / 1e18;
        uint256 expectedBorrow = BASE_INDEX_SCALE + (numerator + 1e18 - 1) / 1e18;

        assertEq(supplyIndex, expectedSupply, "supply index did not floor");
        assertEq(borrowIndex, expectedBorrow, "borrow index did not ceil");
    }

    /// @notice Accrual is idempotent within a block regardless of the rates configured.
    function testFuzz_accrual_isIdempotentWithinABlock(uint256 borrowRate, uint32 elapsed) public {
        borrowRate = bound(borrowRate, 0, 1e12);
        elapsed = uint32(bound(elapsed, 0, 365 days));

        irm.setRates(borrowRate, borrowRate / 2);

        vm.warp(block.timestamp + elapsed);
        market.accrue();
        (uint64 supplyOnce, uint64 borrowOnce) = market.getIndexes();

        market.accrue();
        (uint64 supplyTwice, uint64 borrowTwice) = market.getIndexes();

        assertEq(supplyOnce, supplyTwice, "supply index moved on a second accrual");
        assertEq(borrowOnce, borrowTwice, "borrow index moved on a second accrual");
    }

    /*//////////////////////////////////////////////////////////////
                   INV-1: SINGLE ACCOUNTING PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Totals track the principal split by sign exactly, through arbitrary sign crossings.
    function testFuzz_accountingPath_totalsMatchPrincipalsAcrossCrossings(int104 first, int104 second, int104 third)
        public
    {
        int104 bound_ = int104(uint104(MAX_PRINCIPAL / 1e6));
        first = int104(bound(int256(first), -int256(uint256(uint104(bound_))), int256(uint256(uint104(bound_)))));
        second = int104(bound(int256(second), -int256(uint256(uint104(bound_))), int256(uint256(uint104(bound_)))));
        third = int104(bound(int256(third), -int256(uint256(uint104(bound_))), int256(uint256(uint104(bound_)))));

        address account = address(0xA11CE);

        market.setPrincipal(account, first);
        assertTotalsMatch(account, first);

        market.setPrincipal(account, second);
        assertTotalsMatch(account, second);

        market.setPrincipal(account, third);
        assertTotalsMatch(account, third);
    }

    /// @notice INV-1 across two accounts moving independently, including opposite signs.
    function testFuzz_accountingPath_totalsMatchTwoAccounts(int104 pA, int104 pB) public {
        int104 bound_ = int104(uint104(MAX_PRINCIPAL / 1e6));
        pA = int104(bound(int256(pA), -int256(uint256(uint104(bound_))), int256(uint256(uint104(bound_)))));
        pB = int104(bound(int256(pB), -int256(uint256(uint104(bound_))), int256(uint256(uint104(bound_)))));

        address a = address(0xA);
        address b = address(0xB);

        market.setPrincipal(a, pA);
        market.setPrincipal(b, pB);

        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();

        uint256 expectedSupply = (pA > 0 ? uint256(uint104(pA)) : 0) + (pB > 0 ? uint256(uint104(pB)) : 0);
        uint256 expectedBorrow = magnitude(pA) + magnitude(pB);

        assertEq(totalSupplyBase, expectedSupply, "INV-1 supply side");
        assertEq(totalBorrowBase, expectedBorrow, "INV-1 borrow side");
    }

    /// @dev Debt magnitude of a signed principal, negating in int256 so the min edge is safe.
    function magnitude(int104 principal) internal pure returns (uint256) {
        return principal < 0 ? uint256(-int256(principal)) : 0;
    }

    /// @dev Asserts INV-1 for a single account market: totals equal the account's split principal.
    function assertTotalsMatch(address account, int104 principal) internal view {
        (uint104 totalSupplyBase, uint104 totalBorrowBase) = market.getTotals();

        assertEq(market.getPrincipal(account), principal, "principal not stored");
        assertEq(totalSupplyBase, principal > 0 ? uint104(principal) : 0, "INV-1 supply side");
        assertEq(totalBorrowBase, magnitude(principal), "INV-1 borrow side");
    }
}
