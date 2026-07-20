// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/**
 * @title InterestRateModel
 * @author GushALKDev
 * @notice Stateless, immutable jump-rate curve: one kinked borrow curve with the supply rate
 *         derived from it, so that non-negative reserve accrual is a theorem rather than a
 *         configuration assumption (Guide 3, ADR-4).
 * @dev Every division floors. Flooring the supply rate only lowers what suppliers receive, which
 *      Guide 2, Section 6 proves is reserve-safe at any utilization, including U > 1e18.
 */
contract InterestRateModel is IInterestRateModel {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Scale of per second rates, the reserve factor, and utilization.
    uint256 internal constant RATE_SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Per second borrow rate at zero utilization, 1e18 scale.
    uint256 public immutable BASE_RATE;

    /// @notice Per second slope below the kink, 1e18 scale.
    uint256 public immutable SLOPE_LOW;

    /// @notice Per second slope above the kink, 1e18 scale.
    uint256 public immutable SLOPE_HIGH;

    /// @notice Utilization at which the slope jumps, 1e18 scale.
    uint256 public immutable KINK;

    /// @inheritdoc IInterestRateModel
    /// @dev A public immutable satisfies the interface's RESERVE_FACTOR() getter directly.
    uint256 public immutable RESERVE_FACTOR;

    /// @notice Borrow rate at the kink, precomputed since it anchors the upper branch.
    uint256 internal immutable RATE_AT_KINK;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidConfiguration(bytes32 what);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fixes the curve parameters, enforcing the ordering the solvency math relies on.
     * @param baseRate Per second borrow rate at zero utilization, 1e18 scale.
     * @param slopeLow Per second slope below the kink, 1e18 scale.
     * @param slopeHigh Per second slope above the kink, 1e18 scale.
     * @param kink Utilization at which the slope jumps, strictly between 0 and 1e18.
     * @param reserveFactor Share of borrow interest to reserves, strictly below 1e18.
     */
    constructor(uint256 baseRate, uint256 slopeLow, uint256 slopeHigh, uint256 kink, uint256 reserveFactor) {
        // INV-12: 0 < kink < 1e18, slopeHigh >= slopeLow, RF < 1e18.
        if (kink == 0 || kink >= RATE_SCALE) revert InvalidConfiguration("kink");
        if (slopeHigh < slopeLow) revert InvalidConfiguration("slopeHigh");
        if (reserveFactor >= RATE_SCALE) revert InvalidConfiguration("reserveFactor");

        BASE_RATE = baseRate;
        SLOPE_LOW = slopeLow;
        SLOPE_HIGH = slopeHigh;
        KINK = kink;
        RESERVE_FACTOR = reserveFactor;

        // Both branches must agree at U == kink, so the upper branch starts from this value.
        RATE_AT_KINK = baseRate + FixedPointMathLib.fullMulDiv(slopeLow, kink, RATE_SCALE);
    }

    /*//////////////////////////////////////////////////////////////
                                 RATES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInterestRateModel
    function getBorrowRate(uint256 utilization) public view returns (uint256) {
        // No clamp on utilization: the accounting bounds U to [0, ~1e18], slightly above under
        // legitimate over-utilization (Guide 2, Section 4), while fullMulDiv only overflows at a U
        // many orders of magnitude beyond any constructible state. This matches the standard
        // approach (Aave does not clamp either). See Guide 5, Section 3.2.
        if (utilization <= KINK) {
            return BASE_RATE + FixedPointMathLib.fullMulDiv(SLOPE_LOW, utilization, RATE_SCALE);
        }
        return RATE_AT_KINK + FixedPointMathLib.fullMulDiv(SLOPE_HIGH, utilization - KINK, RATE_SCALE);
    }

    /// @inheritdoc IInterestRateModel
    function getSupplyRate(uint256 utilization) public view returns (uint256) {
        // s = floor( floor( r * U / 1e18 ) * (1e18 - RF) / 1e18 ), both steps flooring so the
        // residual lands in reserves rather than with suppliers.
        uint256 toSuppliers = FixedPointMathLib.fullMulDiv(getBorrowRate(utilization), utilization, RATE_SCALE);
        return FixedPointMathLib.fullMulDiv(toSuppliers, RATE_SCALE - RESERVE_FACTOR, RATE_SCALE);
    }
}
