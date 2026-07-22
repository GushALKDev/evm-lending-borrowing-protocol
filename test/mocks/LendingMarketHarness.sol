// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";

/**
 * @title LendingMarketHarness
 * @notice Concrete deployable market exposing internals for tests, plus stubs for the surface that
 *         later phases fill in.
 * @dev Test only. Phase 4 to 7 replace the reverting stubs (absorb, buyCollateral, the health and
 *      quote views, withdrawReserves) with real implementations in the production contract.
 */
contract LendingMarketHarness is LendingMarket {
    error NotImplemented();

    constructor(MarketConfig memory cfg, CollateralConfig[] memory collaterals) LendingMarket(cfg, collaterals) {}

    /*//////////////////////////////////////////////////////////////
                        EXPOSED INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Drives the single accounting path directly.
    function exposedUpdateBasePrincipal(address account, int104 oldPrincipal, int104 newPrincipal) external {
        _updateBasePrincipal(account, oldPrincipal, newPrincipal);
    }

    /// @notice Sets an account's principal and reconciles totals, starting from its current value.
    function setPrincipal(address account, int104 newPrincipal) external {
        _updateBasePrincipal(account, userBasic[account].principal, newPrincipal);
    }

    /// @notice Overwrites both indexes, so conversions can be tested at arbitrary index states.
    function setIndexes(uint64 supplyIndex, uint64 borrowIndex) external {
        marketState.baseSupplyIndex = supplyIndex;
        marketState.baseBorrowIndex = borrowIndex;
    }

    /// @notice Current base index pair.
    function getIndexes() external view returns (uint64 supplyIndex, uint64 borrowIndex) {
        return (marketState.baseSupplyIndex, marketState.baseBorrowIndex);
    }

    /// @notice Global principal totals.
    function getTotals() external view returns (uint104 totalSupplyBase, uint104 totalBorrowBase) {
        return (marketState.totalSupplyBase, marketState.totalBorrowBase);
    }

    /// @notice The account's collateral membership bitmap.
    function getAssetsIn(address account) external view returns (uint16) {
        return userBasic[account].assetsIn;
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    // The conversion pair is internal in the market: it is implementation detail, not part of
    // ILendingMarket. These wrappers exist so the rounding direction of each site stays directly
    // assertable without widening the deployed ABI.

    function exposedPresentValueSupply(uint104 principal) external view returns (uint256) {
        return _presentValueSupply(principal);
    }

    function exposedPresentValueBorrow(uint104 principal) external view returns (uint256) {
        return _presentValueBorrow(principal);
    }

    function exposedPrincipalValueSupply(uint256 present) external view returns (uint104) {
        return _principalValueSupply(present);
    }

    function exposedPrincipalValueBorrow(uint256 present) external view returns (uint104) {
        return _principalValueBorrow(present);
    }

    function exposedPresentValue(int104 principal) external view returns (int256) {
        return _presentValue(principal);
    }

    function exposedPrincipalValue(int256 present) external view returns (int104) {
        return _principalValue(present);
    }

    /*//////////////////////////////////////////////////////////////
                        NOT YET IMPLEMENTED
    //////////////////////////////////////////////////////////////*/

    // Filled in by Phase 7. Kept as a reverting stub so the market is deployable meanwhile.

    function withdrawReserves(address, uint256) external pure {
        revert NotImplemented();
    }
}
