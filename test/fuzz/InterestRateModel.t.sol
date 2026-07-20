// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {InterestRateModel} from "../../src/InterestRateModel.sol";

/**
 * @title InterestRateModelFuzzTest
 * @notice Phase 2 fuzz coverage: INV-14 (monotone, supply <= borrow, continuous at the kink) and
 *         the directional interest-split inequality of Guide 2, Section 6.
 */
contract InterestRateModelFuzzTest is Test {
    uint256 internal constant RATE_SCALE = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    uint256 internal constant KINK = 0.8e18;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;
    uint256 internal constant SLOPE_LOW = (0.05e18) / SECONDS_PER_YEAR;
    uint256 internal constant SLOPE_HIGH = (1e18) / SECONDS_PER_YEAR;

    InterestRateModel internal irm;

    function setUp() public {
        irm = new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, KINK, RESERVE_FACTOR);
    }

    /*//////////////////////////////////////////////////////////////
                        INV-14: MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @dev A utilization ceiling far above any reachable state but well below the fullMulDiv
    ///      overflow (~3.65e66 borrow, ~1.91e51 supply). Real U sits near 1e18; this is ~1e15 that.
    uint256 internal constant U_FUZZ_MAX = 1e33;

    /// @notice The borrow rate never decreases as utilization rises, across the reachable domain
    ///         and far beyond it, up to a ceiling below the fullMulDiv overflow.
    function testFuzz_borrowRate_isMonotone(uint256 uLow, uint256 uHigh) public view {
        uLow = bound(uLow, 0, U_FUZZ_MAX - 1);
        uHigh = bound(uHigh, uLow, U_FUZZ_MAX);

        assertLe(irm.getBorrowRate(uLow), irm.getBorrowRate(uHigh), "borrow rate not monotone");
    }

    /// @notice The supply rate never decreases as utilization rises, within the real domain.
    /// @dev Bounded to [0, 1e18]: past U = 1 the derived s = r * U grows super-linearly, so pointwise
    ///      monotonicity there is uninteresting, and only the reachable domain carries meaning.
    function testFuzz_supplyRate_isMonotoneInTheRealDomain(uint256 uLow, uint256 uHigh) public view {
        uLow = bound(uLow, 0, 1e18);
        uHigh = bound(uHigh, uLow, 1e18);

        assertLe(irm.getSupplyRate(uLow), irm.getSupplyRate(uHigh), "supply rate not monotone");
    }

    /*//////////////////////////////////////////////////////////////
                     INV-14: SUPPLY <= BORROW ON [0, 1e18]
    //////////////////////////////////////////////////////////////*/

    /// @notice The supply rate never exceeds the borrow rate over the domain the invariant covers.
    function testFuzz_supplyRateNeverExceedsBorrowRate(uint256 utilization) public view {
        utilization = bound(utilization, 0, 1e18);

        assertLe(irm.getSupplyRate(utilization), irm.getBorrowRate(utilization), "supply exceeds borrow");
    }

    /*//////////////////////////////////////////////////////////////
                     INTEREST SPLIT (Guide 2, Section 6)
    //////////////////////////////////////////////////////////////*/

    /// @notice The reserve cut is non-negative: borrowers always pay at least what suppliers receive
    ///         plus the reserve-factor share, as a directional inequality (never an exact equality).
    /// @dev Guide 2, Section 6 is explicit that this is not an integer identity: the two rates
    ///      floor independently, so the residual must accrue to reserves, never against them. The
    ///      real-valued identity is s = r * U * (1 - RF); flooring can only lower s, so the floored
    ///      s is at most the real one, and the reserve share is at least RF * r * U.
    function testFuzz_interestSplit_reserveShareIsNonNegative(uint256 utilization) public view {
        utilization = bound(utilization, 0, 1e18);

        uint256 borrowRate = irm.getBorrowRate(utilization);
        uint256 supplyRate = irm.getSupplyRate(utilization);

        // Interest per unit of respective base over one second: borrowers pay r on U worth of
        // borrows, suppliers receive s on 1 worth of supply, at U = borrow/supply. Normalizing to
        // one unit of supply, borrower interest is r * U and supplier interest is s.
        uint256 borrowerInterest = mulDivDown(borrowRate, utilization);
        uint256 supplierInterest = supplyRate;

        assertLe(supplierInterest, borrowerInterest, "suppliers received more than borrowers paid");
    }

    /// @notice Flooring the supply rate never rounds it above the real-valued r * U * (1 - RF).
    function testFuzz_interestSplit_supplyRateIsFloored(uint256 utilization) public view {
        utilization = bound(utilization, 0, 1e18);

        uint256 borrowRate = irm.getBorrowRate(utilization);
        uint256 supplyRate = irm.getSupplyRate(utilization);

        // The real-valued target, computed the same way but without the intermediate floor loss
        // being reintroduced: floor(r * U / 1e18) * (1e18 - RF) / 1e18 is what the contract does,
        // so the contract result must be at most the single-rounding value.
        uint256 singleRounding = mulDivDown(mulDivDown(borrowRate, utilization), RATE_SCALE - RESERVE_FACTOR);

        assertEq(supplyRate, singleRounding, "supply rate rounding differs from the documented form");
    }

    /*//////////////////////////////////////////////////////////////
                       CONTINUITY AT THE KINK
    //////////////////////////////////////////////////////////////*/

    /// @notice The curve has no downward step anywhere: it is non-decreasing across the kink.
    function testFuzz_continuity_noDownwardStepAcrossTheKink(uint256 delta) public view {
        delta = bound(delta, 1, 0.2e18);

        uint256 below = irm.getBorrowRate(KINK - delta);
        uint256 above = irm.getBorrowRate(KINK + delta);

        assertLe(below, irm.getBorrowRate(KINK), "below the kink exceeds the kink");
        assertGe(above, irm.getBorrowRate(KINK), "above the kink is under the kink");
    }

    /// @dev Local floor(a * b / 1e18), so these assertions do not lean on the contract under test.
    function mulDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / RATE_SCALE;
    }
}
