// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Settable price oracle for local tests, standing in for PythChainlinkOracle until Phase 5.
 * @dev Prices and confidences are set directly. updateAndGetPrice accepts and refunds msg.value so
 *      the market's fee-forwarding path can be exercised without a real Pyth fee.
 */
contract MockPriceOracle is IPriceOracle {
    struct Feed {
        uint256 price18;
        uint256 conf18;
        bool set;
    }

    mapping(address asset => Feed feed) internal feeds;

    error PriceNotSet(address asset);
    error RefundFailed();

    /// @notice Sets the price and confidence for an asset, both at 1e18 scale.
    function setPrice(address asset, uint256 price18, uint256 conf18) external {
        feeds[asset] = Feed({price18: price18, conf18: conf18, set: true});
    }

    /// @notice Clears an asset's feed, so both read paths revert as an unconfigured feed would.
    function unsetPrice(address asset) external {
        delete feeds[asset];
    }

    /// @inheritdoc IPriceOracle
    function updateAndGetPrice(address asset, bytes[] calldata)
        external
        payable
        returns (uint256 price18, uint256 conf18)
    {
        (price18, conf18) = _read(asset);
        // Refund the whole fee: the mock charges nothing, mirroring the real oracle's surplus sweep.
        if (msg.value > 0) {
            (bool ok,) = msg.sender.call{value: msg.value}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price18, uint256 conf18) {
        return _read(asset);
    }

    function _read(address asset) internal view returns (uint256 price18, uint256 conf18) {
        Feed memory feed = feeds[asset];
        if (!feed.set) revert PriceNotSet(asset);
        return (feed.price18, feed.conf18);
    }
}
