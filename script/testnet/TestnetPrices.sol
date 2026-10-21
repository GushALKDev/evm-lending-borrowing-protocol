// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {DemoPyth} from "./DemoPyth.sol";

/**
 * @title TestnetPrices
 * @author GushALKDev
 * @notice The DemoPyth update the demo app sends, built the same way for the testnet scripts: each
 *         Chainlink answer becomes a Pyth price with DEMO_CONF_BPS of confidence half-width, published at
 *         the current block's timestamp.
 */
abstract contract TestnetPrices {
    /// @dev Pyth feed ids, the same as on mainnet, so DemoPyth stores each price under its real id.
    bytes32 internal constant USDC_USD_FEED_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    /// @dev Confidence half-width attached to each mirrored price, in basis points.
    uint256 internal constant DEMO_CONF_BPS = 5;

    /// @dev The full update: USDC, ETH and BTC, in that order. Feeds are the Chainlink anchors, same order.
    function _mirrorAll(DemoPyth pyth, address[3] memory feeds) internal view returns (bytes[] memory update) {
        update = new bytes[](3);
        update[0] = _mirror(pyth, USDC_USD_FEED_ID, feeds[0]);
        update[1] = _mirror(pyth, ETH_USD_FEED_ID, feeds[1]);
        update[2] = _mirror(pyth, BTC_USD_FEED_ID, feeds[2]);
    }

    /// @dev One DemoPyth entry carrying a Chainlink answer.
    function _mirror(DemoPyth pyth, bytes32 id, address feed) internal view returns (bytes memory) {
        (, int256 answer,,,) = IChainlinkAggregator(feed).latestRoundData();
        uint8 feedDecimals = IChainlinkAggregator(feed).decimals();
        // Chainlink answers for these feeds are positive and far inside int64; the oracle checks both.
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 price = int64(answer);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 conf = uint64(uint256(answer) * DEMO_CONF_BPS / 10_000);
        // forge-lint: disable-next-line(unsafe-typecast)
        return pyth.createPriceFeedUpdateData(id, price, conf, -int32(uint32(feedDecimals)), uint64(block.timestamp));
    }
}
