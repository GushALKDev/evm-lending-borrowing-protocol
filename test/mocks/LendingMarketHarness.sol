// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LendingMarket} from "../../src/LendingMarket.sol";

/**
 * @title LendingMarketHarness
 * @notice Exposes the internal accounting path so Phase 1 can test it before user actions exist.
 * @dev Test only. The production market routes these through supply / withdraw / absorb instead.
 */
contract LendingMarketHarness is LendingMarket {
    error NotImplemented();

    constructor(address baseToken, address interestRateModel) LendingMarket(baseToken, interestRateModel) {}

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

    /*//////////////////////////////////////////////////////////////
                        CONVERSION PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    // The conversion pair is internal in the market: it is implementation detail, not part of
    // ILendingMarket. These wrappers exist so the rounding direction of each site stays directly
    // assertable without widening the deployed ABI.

    /// @notice Present value of a positive base principal, rounds down.
    function exposedPresentValueSupply(uint104 principal) external view returns (uint256) {
        return _presentValueSupply(principal);
    }

    /// @notice Present value magnitude of a debt principal, rounds up.
    function exposedPresentValueBorrow(uint104 principal) external view returns (uint256) {
        return _presentValueBorrow(principal);
    }

    /// @notice Supply principal for a present value, rounds down.
    function exposedPrincipalValueSupply(uint256 present) external view returns (uint104) {
        return _principalValueSupply(present);
    }

    /// @notice Debt principal magnitude for a debt present value, rounds up.
    function exposedPrincipalValueBorrow(uint256 present) external view returns (uint104) {
        return _principalValueBorrow(present);
    }

    /// @notice Signed present value of a signed principal.
    function exposedPresentValue(int104 principal) external view returns (int256) {
        return _presentValue(principal);
    }

    /// @notice Signed principal for a signed present value.
    function exposedPrincipalValue(int256 present) external view returns (int104) {
        return _principalValue(present);
    }

    /*//////////////////////////////////////////////////////////////
                        NOT YET IMPLEMENTED
    //////////////////////////////////////////////////////////////*/

    // The user facing surface lands in Phases 3 to 7. These stubs exist only so the Phase 1
    // accounting core is deployable and testable against the full ILendingMarket type.

    function supply(address, uint256) external pure {
        revert NotImplemented();
    }

    function withdraw(address, uint256, bytes[] calldata) external payable {
        revert NotImplemented();
    }

    function absorb(address, bytes[] calldata) external payable {
        revert NotImplemented();
    }

    function buyCollateral(address, uint256, uint256, address, bytes[] calldata) external payable {
        revert NotImplemented();
    }

    function withdrawReserves(address, uint256) external pure {
        revert NotImplemented();
    }

    function setPauseFlags(uint8) external pure {
        revert NotImplemented();
    }

    function isBorrowCollateralized(address) external pure returns (bool) {
        revert NotImplemented();
    }

    function isLiquidatable(address) external pure returns (bool) {
        revert NotImplemented();
    }

    function quoteCollateral(address, uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    function userCollateral(address, address) external pure returns (uint128) {
        revert NotImplemented();
    }
}
