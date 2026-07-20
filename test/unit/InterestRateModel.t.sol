// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {InterestRateModel} from "../../src/InterestRateModel.sol";

/**
 * @title InterestRateModelTest
 * @notice Phase 2 unit coverage: the kinked curve, the derived supply rate, continuity at the
 *         kink, and the constructor revert matrix.
 * @dev Reference parameterization from Guide 2, Section 5: baseRate 0, 4% APR at the kink,
 *      kink 80%, slopeHigh 100%/year, reserve factor 10%.
 */
contract InterestRateModelTest is Test {
    uint256 internal constant RATE_SCALE = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    uint256 internal constant KINK = 0.8e18;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;

    // slopeLow is sized so the borrow rate reaches 4% APR exactly at the 80% kink: 5%/year.
    uint256 internal constant SLOPE_LOW = (0.05e18) / SECONDS_PER_YEAR;
    uint256 internal constant SLOPE_HIGH = (1e18) / SECONDS_PER_YEAR;

    InterestRateModel internal irm;

    function setUp() public {
        irm = new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, KINK, RESERVE_FACTOR);
    }

    /// @dev Converts a per second rate to an APR at 1e18 scale, for readable assertions.
    function apr(uint256 perSecond) internal pure returns (uint256) {
        return perSecond * SECONDS_PER_YEAR;
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR (2.2)
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesParameters() public view {
        assertEq(irm.BASE_RATE(), 0, "base rate");
        assertEq(irm.SLOPE_LOW(), SLOPE_LOW, "slope low");
        assertEq(irm.SLOPE_HIGH(), SLOPE_HIGH, "slope high");
        assertEq(irm.KINK(), KINK, "kink");
        assertEq(irm.RESERVE_FACTOR(), RESERVE_FACTOR, "reserve factor");
    }

    function test_constructor_revertsOnZeroKink() public {
        vm.expectRevert(abi.encodeWithSelector(InterestRateModel.InvalidConfiguration.selector, bytes32("kink")));
        new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, 0, RESERVE_FACTOR);
    }

    function test_constructor_revertsOnKinkAtOrAboveOne() public {
        vm.expectRevert(abi.encodeWithSelector(InterestRateModel.InvalidConfiguration.selector, bytes32("kink")));
        new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, RATE_SCALE, RESERVE_FACTOR);
    }

    function test_constructor_revertsWhenSlopeHighBelowSlopeLow() public {
        vm.expectRevert(abi.encodeWithSelector(InterestRateModel.InvalidConfiguration.selector, bytes32("slopeHigh")));
        new InterestRateModel(0, SLOPE_HIGH, SLOPE_LOW, KINK, RESERVE_FACTOR);
    }

    function test_constructor_revertsOnReserveFactorAtOrAboveOne() public {
        vm.expectRevert(
            abi.encodeWithSelector(InterestRateModel.InvalidConfiguration.selector, bytes32("reserveFactor"))
        );
        new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, KINK, RATE_SCALE);
    }

    /// @dev slopeHigh == slopeLow is legal (a straight line), only strictly below is rejected.
    function test_constructor_allowsEqualSlopes() public {
        InterestRateModel flat = new InterestRateModel(0, SLOPE_LOW, SLOPE_LOW, KINK, RESERVE_FACTOR);
        assertEq(flat.SLOPE_HIGH(), SLOPE_LOW, "equal slopes accepted");
    }

    /*//////////////////////////////////////////////////////////////
                      REFERENCE CURVE (2.3, 2.4)
    //////////////////////////////////////////////////////////////*/

    // The documented table from Guide 2, Section 5. Tolerances absorb the per second truncation.

    function test_borrowRate_isBaseRateAtZeroUtilization() public view {
        assertEq(irm.getBorrowRate(0), 0, "idle borrow rate");
        assertEq(irm.getSupplyRate(0), 0, "idle supply rate");
    }

    function test_curve_matchesDocumentedTableAtHalfUtilization() public view {
        assertApproxEqRel(apr(irm.getBorrowRate(0.5e18)), 0.025e18, 0.001e18, "2.5% APR borrow");
        assertApproxEqRel(apr(irm.getSupplyRate(0.5e18)), 0.01125e18, 0.001e18, "1.125% APR supply");
    }

    function test_curve_matchesDocumentedTableAtTheKink() public view {
        assertApproxEqRel(apr(irm.getBorrowRate(KINK)), 0.04e18, 0.001e18, "4% APR borrow");
        assertApproxEqRel(apr(irm.getSupplyRate(KINK)), 0.0288e18, 0.001e18, "2.88% APR supply");
    }

    function test_curve_matchesDocumentedTableInTheJumpRegime() public view {
        assertApproxEqRel(apr(irm.getBorrowRate(0.9e18)), 0.14e18, 0.001e18, "14% APR borrow");
        assertApproxEqRel(apr(irm.getSupplyRate(0.9e18)), 0.1134e18, 0.001e18, "11.34% APR supply");
    }

    function test_curve_matchesDocumentedTableAtFullUtilization() public view {
        assertApproxEqRel(apr(irm.getBorrowRate(1e18)), 0.24e18, 0.001e18, "24% APR borrow");
        assertApproxEqRel(apr(irm.getSupplyRate(1e18)), 0.216e18, 0.001e18, "21.6% APR supply");
    }

    /*//////////////////////////////////////////////////////////////
                        CONTINUITY AT THE KINK
    //////////////////////////////////////////////////////////////*/

    /// @dev Both branches must agree exactly at U == kink: the curve has no step.
    function test_continuity_branchesAgreeAtTheKink() public view {
        uint256 atKink = irm.getBorrowRate(KINK);
        uint256 justBelow = irm.getBorrowRate(KINK - 1);
        uint256 justAbove = irm.getBorrowRate(KINK + 1);

        assertLe(justBelow, atKink, "lower branch overshoots the kink");
        assertGe(justAbove, atKink, "upper branch undershoots the kink");

        // The jump across one wei of utilization is bounded by the steeper slope.
        assertLe(justAbove - atKink, SLOPE_HIGH, "discontinuity at the kink");
    }

    /// @dev The upper branch is anchored on the lower branch's value at the kink.
    function test_continuity_upperBranchStartsFromTheKinkRate() public view {
        uint256 expectedAtKink = (SLOPE_LOW * KINK) / RATE_SCALE;
        assertEq(irm.getBorrowRate(KINK), expectedAtKink, "kink rate mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                     REACHABLE DOMAIN AND OVERFLOW
    //////////////////////////////////////////////////////////////*/

    // The rate functions are not clamped. Utilization is bounded by the accounting, not by the
    // curve: U = totalBorrowPV * 1e18 / totalSupplyPV, and with totalBorrow <= totalSupply it sits
    // in [0, ~1e18], reaching only slightly above 1e18 under legitimate over-utilization (Guide 2,
    // Section 4). The theoretical fullMulDiv overflow sits many orders of magnitude beyond any
    // constructible state, so no clamp is warranted. Aave does not clamp either. See Guide 5,
    // Section 3.2. These tests document that gap; they do not defend a reachable state.

    /// @dev A generous over-utilization ceiling. Real markets never exceed a small multiple of 1e18.
    uint256 internal constant U_HIGH = 10e18; // 1000% utilization, already unreachable in practice

    function test_domain_doesNotRevertThroughOverUtilization() public view {
        assertGt(irm.getBorrowRate(2e18), irm.getBorrowRate(1e18), "rate keeps rising past U = 1");
        assertGt(irm.getSupplyRate(2e18), irm.getSupplyRate(1e18), "supply rate keeps rising");
        // Well past any real state, both still return without reverting.
        irm.getBorrowRate(U_HIGH);
        irm.getSupplyRate(U_HIGH);
    }

    /// @dev The supply rate overflows the fullMulDiv only at a U ~1.9e33 times full utilization.
    ///      This pins how astronomically far the overflow is from anything the market can produce:
    ///      U is bounded to roughly [0, 1e18] by the accounting, so the margin is ~33 orders.
    function test_domain_overflowIsUnreachablyFarAboveRealUtilization() public {
        // supplyRate computes r * U / 1e18; the binding overflow is that product. It still returns
        // just below the threshold (~1.91e51) and reverts just above it.
        irm.getSupplyRate(1e51); // ~1e33 x full utilization: still fine

        // At 2e51 the r * U product overflows fullMulDiv and the call reverts. This is correct:
        // such a U is unconstructible, so a revert here can never gate accrue() in practice.
        vm.expectRevert();
        this.callSupplyRate(2e51);
    }

    /// @dev External wrapper so vm.expectRevert can catch the library revert cleanly.
    function callSupplyRate(uint256 utilization) external view returns (uint256) {
        return irm.getSupplyRate(utilization);
    }

    /// @dev The borrow rate, with only one multiplication, tolerates far higher U than the supply
    ///      rate before overflowing: another marker of how much headroom the real domain has.
    function test_domain_borrowRateToleratesEvenHigherUtilization() public view {
        // 1e40 x full utilization still returns for the borrow rate.
        assertGt(irm.getBorrowRate(1e18 * 1e40), irm.getBorrowRate(1e18), "borrow rate still climbing");
    }

    /*//////////////////////////////////////////////////////////////
                          RESERVE FACTOR EDGE
    //////////////////////////////////////////////////////////////*/

    /// @dev With RF = 0 the whole borrow interest reaches suppliers: s = r * U.
    function test_reserveFactor_zeroPassesEverythingToSuppliers() public {
        InterestRateModel noCut = new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, KINK, 0);

        uint256 borrowRate = noCut.getBorrowRate(1e18);
        assertEq(noCut.getSupplyRate(1e18), borrowRate, "at U = 1 and RF = 0, s equals r");
    }

    /// @dev The supply rate is strictly below the borrow rate whenever the reserve factor bites.
    function test_reserveFactor_divertsTheDocumentedShare() public view {
        uint256 borrowRate = irm.getBorrowRate(1e18);
        uint256 supplyRate = irm.getSupplyRate(1e18);

        // At U = 1, s = r * (1 - RF), so the gap is exactly the reserve factor's share.
        assertApproxEqRel(supplyRate, (borrowRate * 9) / 10, 0.001e18, "reserve factor share");
    }
}
