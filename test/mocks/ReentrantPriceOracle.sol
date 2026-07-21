// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";

/**
 * @title ReentrantPriceOracle
 * @notice Malicious oracle that calls back into the market from updateAndGetPrice.
 * @dev The borrow path writes the principal, then calls the oracle, then transfers tokens. That
 *      leaves an external call in the middle of a state-changing function, so the reentrancy guard
 *      is what makes the ordering safe rather than merely conventional. This mock exists to prove
 *      the guard holds instead of arguing that it does.
 */
contract ReentrantPriceOracle is IPriceOracle {
    mapping(address asset => uint256 price) public prices;

    ILendingMarket public market;
    address public attackAsset;
    uint256 public attackAmount;
    bool public attacked;

    error PriceNotSet(address asset);

    function setPrice(address asset, uint256 price18) external {
        prices[asset] = price18;
    }

    /// @notice Arms a single reentrant withdraw attempt on the next price read.
    function arm(address market_, address asset, uint256 amount) external {
        market = ILendingMarket(market_);
        attackAsset = asset;
        attackAmount = amount;
        attacked = false;
    }

    /// @inheritdoc IPriceOracle
    function updateAndGetPrice(address asset, bytes[] calldata)
        external
        payable
        returns (uint256 price18, uint256 conf18)
    {
        // Fire once: the point is to prove the first reentry is refused, not to loop forever.
        if (address(market) != address(0) && !attacked) {
            attacked = true;
            market.withdraw(attackAsset, attackAmount, new bytes[](0));
        }
        return (_read(asset), 0);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price18, uint256 conf18) {
        return (_read(asset), 0);
    }

    function _read(address asset) internal view returns (uint256) {
        uint256 price = prices[asset];
        if (price == 0) revert PriceNotSet(asset);
        return price;
    }
}
