// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IInterestRateModel
 * @author GushALKDev
 * @notice Stateless, immutable interest rate policy consumed by the market on every accrual.
 * @dev Both rate functions are total over the full uint256 domain: utilization above 1e18 is a
 *      reachable market state (see Guide 2, Section 4) and must never revert.
 */
interface IInterestRateModel {
    /**
     * @notice Per-second borrow rate for a given utilization.
     * @param utilization Utilization at 1e18 scale, may exceed 1e18.
     * @return Per-second borrow rate at 1e18 scale.
     */
    function getBorrowRate(uint256 utilization) external view returns (uint256);

    /**
     * @notice Per-second supply rate, derived as borrowRate * utilization * (1 - reserveFactor).
     * @param utilization Utilization at 1e18 scale, may exceed 1e18.
     * @return Per-second supply rate at 1e18 scale.
     */
    function getSupplyRate(uint256 utilization) external view returns (uint256);

    /**
     * @notice Share of borrow interest diverted to protocol reserves.
     * @return Reserve factor at 1e18 scale, strictly below 1e18.
     */
    // solhint-disable-next-line func-name-mixedcase
    function RESERVE_FACTOR() external view returns (uint256);
}
