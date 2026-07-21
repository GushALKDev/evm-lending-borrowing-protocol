// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";

/**
 * @title MockChainlinkFeed
 * @notice Settable Chainlink aggregator for local oracle tests, standing in for a real feed.
 * @dev Answer, updatedAt, and decimals are set directly so the deviation anchor and its heartbeat
 *      staleness check can be driven on demand.
 */
contract MockChainlinkFeed is IChainlinkAggregator {
    int256 internal answer;
    uint256 internal updatedAt;
    uint8 internal feedDecimals;
    uint80 internal roundId;

    constructor(uint8 _decimals, int256 _answer, uint256 _updatedAt) {
        feedDecimals = _decimals;
        answer = _answer;
        updatedAt = _updatedAt;
        roundId = 1;
    }

    /// @notice Sets the answer and its update timestamp, bumping the round.
    function setAnswer(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
        roundId += 1;
    }

    /// @inheritdoc IChainlinkAggregator
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    /// @inheritdoc IChainlinkAggregator
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }
}
