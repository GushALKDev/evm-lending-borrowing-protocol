// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";

/**
 * @title MockInterestRateModel
 * @notice Rate model with directly settable rates, so accrual can be driven to exact values.
 * @dev Lets Phase 1 test index accrual in isolation from the real curve, which lands in Phase 2.
 */
contract MockInterestRateModel is IInterestRateModel {
    uint256 public borrowRate;
    uint256 public supplyRate;
    uint256 public reserveFactor;

    constructor(uint256 borrowRate_, uint256 supplyRate_, uint256 reserveFactor_) {
        borrowRate = borrowRate_;
        supplyRate = supplyRate_;
        reserveFactor = reserveFactor_;
    }

    /// @notice Sets both per second rates at 1e18 scale.
    function setRates(uint256 borrowRate_, uint256 supplyRate_) external {
        borrowRate = borrowRate_;
        supplyRate = supplyRate_;
    }

    /// @inheritdoc IInterestRateModel
    function getBorrowRate(uint256) external view returns (uint256) {
        return borrowRate;
    }

    /// @inheritdoc IInterestRateModel
    function getSupplyRate(uint256) external view returns (uint256) {
        return supplyRate;
    }

    /// @inheritdoc IInterestRateModel
    // solhint-disable-next-line func-name-mixedcase
    function RESERVE_FACTOR() external view returns (uint256) {
        return reserveFactor;
    }
}
