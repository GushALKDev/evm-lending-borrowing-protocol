// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IChainlinkAggregator
 * @author GushALKDev
 * @notice Minimal Chainlink AggregatorV3 surface the oracle needs for the deviation anchor.
 * @dev Only latestRoundData (for the anchor price and its freshness) and decimals (for
 *      normalization) are consumed. The full aggregator surface is intentionally not vendored.
 */
interface IChainlinkAggregator {
    /**
     * @notice Latest round of the aggregator.
     * @return roundId The round ID.
     * @return answer The price answer in the feed's own decimals.
     * @return startedAt Timestamp the round started.
     * @return updatedAt Timestamp the round was last updated, used for the heartbeat staleness check.
     * @return answeredInRound The round the answer was computed in.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Decimals of the feed's answer, used to normalize the anchor price to 1e18.
    function decimals() external view returns (uint8);
}
