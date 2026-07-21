// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";

/**
 * @title PythChainlinkOracle
 * @author GushALKDev
 * @notice Validated price source for the market: Pyth pull oracle as the primary price, Chainlink as
 *         an independent deviation anchor. Never a silent fallback: any failed check reverts.
 * @dev Pure policy, no owner and no setters (Guide 5, Section 6). Every feed is fixed at construction.
 *      Both read paths run the same validation pipeline (Guide 3, Section 5): non-zero, staleness,
 *      confidence, and Chainlink deviation. Prices and confidences are returned at 1e18 scale; the
 *      market picks the confidence band edge per context.
 */
contract PythChainlinkOracle is IPriceOracle {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error StalePrice(address asset, uint256 publishTime, uint256 maxStaleness);
    error ConfidenceTooWide(address asset, uint256 confBps, uint256 maxConfBps);
    error ZeroPrice(address asset);
    error PriceDeviationTooHigh(address asset, uint256 deviationBps, uint256 maxDeviationBps);
    error StaleAnchor(address asset, uint256 updatedAt, uint256 heartbeat);
    error InsufficientFee(uint256 provided, uint256 required);
    error RefundFailed();
    error UnknownAsset(address asset);
    error InvalidConfiguration(bytes32 what);

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Per-asset feed wiring: the Pyth price ID, the Chainlink anchor, and its heartbeat.
     * @dev heartbeat is the anchor's own staleness window (Guide 5: per feed, not one global value).
     */
    struct FeedConfig {
        bytes32 pythFeedId; // Slot 0
        address chainlinkFeed; // 20 bytes ─┐
        uint32 heartbeat; //  4 bytes  │  Slot 1 (24 bytes)
        bool set; //  1 byte  ─┘
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis-point scale for the confidence and deviation checks.
    uint256 internal constant BPS_SCALE = 10_000;

    /// @notice Target scale of every returned price and confidence.
    uint256 internal constant PRICE_SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Pyth pull oracle the primary price is read from.
    IPyth public immutable PYTH;

    /// @notice Maximum age of a Pyth price before it is rejected as stale, in seconds.
    uint256 public immutable MAX_STALENESS;

    /// @notice Maximum accepted confidence half-width as a fraction of price, in basis points.
    uint256 public immutable MAX_CONFIDENCE_BPS;

    /// @notice Maximum accepted Pyth-vs-Chainlink deviation, in basis points.
    uint256 public immutable MAX_DEVIATION_BPS;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-asset feed wiring, populated once in the constructor.
    mapping(address asset => FeedConfig config) internal feedConfig;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Wires the Pyth oracle, the validation thresholds, and every asset's feed config.
     * @dev No setters exist after this: the oracle is immutable policy. The three feed arrays are
     *      parallel and must share a length.
     * @param pyth Pyth pull oracle address.
     * @param maxStaleness Max Pyth price age in seconds.
     * @param maxConfidenceBps Max confidence half-width over price, in basis points.
     * @param maxDeviationBps Max Pyth-vs-Chainlink deviation, in basis points.
     * @param assets Assets to configure a feed for (base plus every collateral).
     * @param configs Feed config for each asset, index-aligned with assets.
     */
    constructor(
        address pyth,
        uint256 maxStaleness,
        uint256 maxConfidenceBps,
        uint256 maxDeviationBps,
        address[] memory assets,
        FeedConfig[] memory configs
    ) {
        if (pyth == address(0)) revert InvalidConfiguration("pyth");
        if (maxStaleness == 0) revert InvalidConfiguration("maxStaleness");
        if (maxConfidenceBps == 0 || maxConfidenceBps >= BPS_SCALE) revert InvalidConfiguration("maxConfidenceBps");
        if (maxDeviationBps == 0 || maxDeviationBps >= BPS_SCALE) revert InvalidConfiguration("maxDeviationBps");
        if (assets.length != configs.length) revert InvalidConfiguration("length");

        PYTH = IPyth(pyth);
        MAX_STALENESS = maxStaleness;
        MAX_CONFIDENCE_BPS = maxConfidenceBps;
        MAX_DEVIATION_BPS = maxDeviationBps;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            FeedConfig memory config = configs[i];
            if (asset == address(0)) revert InvalidConfiguration("asset");
            if (config.pythFeedId == bytes32(0)) revert InvalidConfiguration("pythFeedId");
            if (config.chainlinkFeed == address(0)) revert InvalidConfiguration("chainlinkFeed");
            if (config.heartbeat == 0) revert InvalidConfiguration("heartbeat");
            if (feedConfig[asset].set) revert InvalidConfiguration("duplicate");
            config.set = true;
            feedConfig[asset] = config;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE READS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceOracle
    function updateAndGetPrice(address asset, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 price18, uint256 conf18)
    {
        uint256 fee = PYTH.getUpdateFee(priceUpdate);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        PYTH.updatePriceFeeds{value: fee}(priceUpdate);

        (price18, conf18) = _validate(asset);

        // Refund the surplus so the market's forwarded balance survives for its next per-asset call
        // and the final sweep. Effects (the on-chain update) happened before this interaction.
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price18, uint256 conf18) {
        return _validate(asset);
    }

    /**
     * @notice Reads the asset's Pyth price and Chainlink anchor and runs the full validation pipeline.
     * @dev The one place the pipeline lives, shared by both read paths so a view can never disagree
     *      with the transactional check. Reads the stored Pyth price with getPriceUnsafe and applies
     *      this contract's own MAX_STALENESS rather than Pyth's validTimePeriod, so lending's looser
     *      staleness policy governs both paths identically.
     * @param asset Asset to price.
     * @return price18 Validated Pyth mid price at 1e18 scale, strictly positive.
     * @return conf18 Pyth confidence half-width at 1e18 scale.
     */
    function _validate(address asset) internal view returns (uint256 price18, uint256 conf18) {
        FeedConfig memory config = feedConfig[asset];
        if (!config.set) revert UnknownAsset(asset);

        // --- Pyth: primary price ---
        PythStructs.Price memory pythPrice = PYTH.getPriceUnsafe(config.pythFeedId);

        if (pythPrice.price <= 0) revert ZeroPrice(asset);
        if (pythPrice.publishTime + MAX_STALENESS < block.timestamp) {
            revert StalePrice(asset, pythPrice.publishTime, MAX_STALENESS);
        }

        price18 = _scalePyth(uint64(pythPrice.price), pythPrice.expo);
        conf18 = _scalePyth(pythPrice.conf, pythPrice.expo);

        // Confidence relative to price, in basis points.
        uint256 confBps = (conf18 * BPS_SCALE) / price18;
        if (confBps > MAX_CONFIDENCE_BPS) revert ConfidenceTooWide(asset, confBps, MAX_CONFIDENCE_BPS);

        // --- Chainlink: deviation anchor ---
        uint256 anchor18 = _readAnchor(asset, config);

        uint256 diff = price18 > anchor18 ? price18 - anchor18 : anchor18 - price18;
        uint256 deviationBps = (diff * BPS_SCALE) / anchor18;
        if (deviationBps > MAX_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(asset, deviationBps, MAX_DEVIATION_BPS);
        }
    }

    /**
     * @notice Reads and normalizes the Chainlink anchor price, checking its own heartbeat freshness.
     * @param asset Asset being priced (for error context).
     * @param config Feed config carrying the aggregator and its heartbeat.
     * @return anchor18 Anchor price at 1e18 scale, strictly positive.
     */
    function _readAnchor(address asset, FeedConfig memory config) internal view returns (uint256 anchor18) {
        IChainlinkAggregator feed = IChainlinkAggregator(config.chainlinkFeed);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        if (answer <= 0) revert ZeroPrice(asset);
        if (updatedAt + config.heartbeat < block.timestamp) {
            revert StaleAnchor(asset, updatedAt, config.heartbeat);
        }

        // Chainlink answers are typically 8 decimals; normalize whatever the feed reports to 1e18.
        uint8 feedDecimals = feed.decimals();
        anchor18 = _scaleTo18(uint256(answer), feedDecimals);
    }

    /*//////////////////////////////////////////////////////////////
                            NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Normalizes a Pyth fixed-point value (`value * 10^expo`) to 1e18 scale.
     * @dev Pyth prices carry a signed exponent, almost always negative (e.g. -8). The target
     *      exponent is `18 + expo`: positive scales up, negative scales down.
     * @param value Absolute Pyth mantissa (price or conf), already known non-negative by the caller.
     * @param expo Pyth exponent.
     * @return Value at 1e18 scale.
     */
    function _scalePyth(uint256 value, int32 expo) internal pure returns (uint256) {
        int256 targetExpo = int256(18) + int256(expo);
        if (targetExpo >= 0) {
            return value * (10 ** uint256(targetExpo));
        }
        return value / (10 ** uint256(-targetExpo));
    }

    /**
     * @notice Normalizes an integer with `decimals` decimals to 1e18 scale.
     * @param value Value in its own decimals.
     * @param decimals Decimals of value; must not exceed 18 for a well-formed feed.
     * @return Value at 1e18 scale.
     */
    function _scaleTo18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals > 18) revert InvalidConfiguration("decimals");
        return value * (10 ** (18 - decimals));
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the feed wiring configured for an asset.
    function getFeedConfig(address asset) external view returns (FeedConfig memory) {
        return feedConfig[asset];
    }
}
