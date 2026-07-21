// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title PythChainlinkOracleTest
 * @notice Phase 5 coverage: the four-stage validation pipeline (non-zero, staleness, confidence,
 *         Chainlink deviation), 1e18 normalization from Pyth expo and Chainlink decimals, the Pyth
 *         fee accounting with surplus refund, and the constructor config guards.
 */
contract PythChainlinkOracleTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal chainlink;
    PythChainlinkOracle internal oracle;

    address internal constant WETH = address(0xE7);
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");

    uint256 internal constant MAX_STALENESS = 60;
    uint256 internal constant MAX_CONF_BPS = 200;
    uint256 internal constant MAX_DEV_BPS = 300;

    uint256 internal constant FEE = 1 wei;
    int32 internal constant PYTH_EXPO = -8;

    function setUp() public {
        // validTimePeriod is only used by Pyth's own getPrice, which the oracle bypasses via
        // getPriceUnsafe; set it large so the mock never reverts before our own staleness check.
        pyth = new MockPyth(365 days, FEE);
        chainlink = new MockChainlinkFeed(8, 2000e8, block.timestamp);

        oracle = _deploy();

        // Seed the Pyth feed with a fresh WETH price at $2000, conf $2 (10 bps).
        _pushPyth(2000e8, 2e8, block.timestamp);
    }

    function _deploy() internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](1);
        assets[0] = WETH;

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](1);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(chainlink), heartbeat: 3600, set: false
        });

        return new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    /// @dev Encodes and pushes a single WETH price update into the mock Pyth, paying the fee.
    /// @dev MockPyth only stores a strictly newer publishTime, so re-pushing at the current
    ///      timestamp advances the clock by one second first and refreshes the anchor to match.
    function _pushPyth(int64 price, uint64 conf, uint256 publishTime) internal {
        bytes[] memory update = new bytes[](1);
        update[0] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, price, conf, PYTH_EXPO, price, conf, uint64(publishTime));
        pyth.updatePriceFeeds{value: FEE}(update);
    }

    /// @dev Advances one second and re-pushes a fresh Pyth price + anchor at the new timestamp,
    ///      so the store accepts the update and staleness stays satisfied.
    function _repushFresh(int64 price, uint64 conf) internal {
        vm.warp(block.timestamp + 1);
        _pushPyth(price, conf, block.timestamp);
        chainlink.setAnswer(int256(price), block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATH + NORM
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_normalizesTo1e18() public view {
        (uint256 price18, uint256 conf18) = oracle.getPrice(WETH);
        assertEq(price18, 2000e18, "price scaled to 1e18");
        assertEq(conf18, 2e18, "conf scaled to 1e18");
    }

    function test_getPrice_positiveExpoScalesUp() public {
        // A positive expo (value * 10^expo) means the mantissa is smaller than the real number:
        // 20 * 10^2 = 2000, so price18 must still be 2000e18.
        bytes[] memory update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(WETH_FEED_ID, 20, 0, int32(2), 20, 0, uint64(block.timestamp));
        pyth.updatePriceFeeds{value: FEE}(update);

        (uint256 price18,) = oracle.getPrice(WETH);
        assertEq(price18, 2000e18, "positive expo scales up to 1e18");
    }

    function test_chainlink_nonEightDecimalsNormalize() public {
        // An 18-decimal Chainlink feed at $2000 must anchor identically to the 8-decimal one.
        MockChainlinkFeed feed18 = new MockChainlinkFeed(18, 2000e18, block.timestamp);
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](1);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(feed18), heartbeat: 3600, set: false
        });
        PythChainlinkOracle o =
            new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);

        (uint256 price18,) = o.getPrice(WETH);
        assertEq(price18, 2000e18, "18-dec anchor accepted");
    }

    /*//////////////////////////////////////////////////////////////
                              STALENESS
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revertsOnStalePyth() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythChainlinkOracle.StalePrice.selector, WETH, block.timestamp - MAX_STALENESS - 1, MAX_STALENESS
            )
        );
        oracle.getPrice(WETH);
    }

    function test_getPrice_freshAtExactBoundary() public {
        // publishTime + MAX_STALENESS == block.timestamp is still fresh (strict-less-than reverts).
        vm.warp(block.timestamp + MAX_STALENESS);
        (uint256 price18,) = oracle.getPrice(WETH);
        assertEq(price18, 2000e18, "exact boundary accepted");
    }

    function test_getPrice_revertsOnStaleAnchor() public {
        // Advance past the anchor heartbeat while keeping the Pyth price fresh.
        vm.warp(block.timestamp + 3601);
        _pushPyth(2000e8, 2e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.StaleAnchor.selector, WETH, block.timestamp - 3601, uint32(3600))
        );
        oracle.getPrice(WETH);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIDENCE
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revertsOnWideConfidence() public {
        // conf $50 on $2000 = 250 bps > 200 bps max.
        _repushFresh(2000e8, 50e8);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.ConfidenceTooWide.selector, WETH, uint256(250), MAX_CONF_BPS)
        );
        oracle.getPrice(WETH);
    }

    function test_getPrice_acceptsConfidenceAtBoundary() public {
        // conf $40 on $2000 = exactly 200 bps, accepted.
        _repushFresh(2000e8, 40e8);
        (, uint256 conf18) = oracle.getPrice(WETH);
        assertEq(conf18, 40e18, "conf at exact boundary accepted");
    }

    /*//////////////////////////////////////////////////////////////
                             DEVIATION
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revertsOnDeviation() public {
        // Chainlink at $2100 vs Pyth $2000 = 100/2100 ~= 476 bps > 300.
        chainlink.setAnswer(2100e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.PriceDeviationTooHigh.selector, WETH, uint256(476), MAX_DEV_BPS)
        );
        oracle.getPrice(WETH);
    }

    function test_getPrice_acceptsWithinDeviation() public {
        // Chainlink at $2050 vs Pyth $2000 = 50/2050 ~= 243 bps <= 300.
        chainlink.setAnswer(2050e8, block.timestamp);
        (uint256 price18,) = oracle.getPrice(WETH);
        assertEq(price18, 2000e18, "within-band deviation accepted");
    }

    /*//////////////////////////////////////////////////////////////
                             ZERO PRICE
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revertsOnZeroPyth() public {
        _repushFresh(0, 0);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.ZeroPrice.selector, WETH));
        oracle.getPrice(WETH);
    }

    function test_getPrice_revertsOnNegativeAnchor() public {
        chainlink.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.ZeroPrice.selector, WETH));
        oracle.getPrice(WETH);
    }

    function test_getPrice_revertsOnUnknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.UnknownAsset.selector, address(0xDEAD)));
        oracle.getPrice(address(0xDEAD));
    }

    /*//////////////////////////////////////////////////////////////
                         UPDATE + FEE / REFUND
    //////////////////////////////////////////////////////////////*/

    function test_updateAndGetPrice_pushesAndValidates() public {
        // Advance so the pushed update is strictly newer than the seeded one and gets stored.
        vm.warp(block.timestamp + 1);
        bytes[] memory update = new bytes[](1);
        update[0] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, 2100e8, 3e8, PYTH_EXPO, 2100e8, 3e8, uint64(block.timestamp));
        chainlink.setAnswer(2100e8, block.timestamp);

        (uint256 price18, uint256 conf18) = oracle.updateAndGetPrice{value: FEE}(WETH, update);
        assertEq(price18, 2100e18, "pushed price returned");
        assertEq(conf18, 3e18, "pushed conf returned");
    }

    function test_updateAndGetPrice_refundsSurplus() public {
        bytes[] memory update = new bytes[](1);
        update[0] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, 2000e8, 2e8, PYTH_EXPO, 2000e8, 2e8, uint64(block.timestamp));

        uint256 sent = FEE + 1 ether;
        uint256 balBefore = address(this).balance;
        oracle.updateAndGetPrice{value: sent}(WETH, update);

        // Only the fee is consumed; the surplus is refunded, so net spend is exactly FEE.
        assertEq(balBefore - address(this).balance, FEE, "surplus refunded");
        assertEq(address(oracle).balance, 0, "oracle holds no ETH");
    }

    function test_updateAndGetPrice_revertsOnInsufficientFee() public {
        bytes[] memory update = new bytes[](1);
        update[0] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, 2000e8, 2e8, PYTH_EXPO, 2000e8, 2e8, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientFee.selector, uint256(0), FEE));
        oracle.updateAndGetPrice{value: 0}(WETH, update);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroPyth() public {
        address[] memory assets = new address[](0);
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](0);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("pyth")));
        new PythChainlinkOracle(address(0), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    function test_constructor_revertsOnLengthMismatch() public {
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](0);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("length")));
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    function test_constructor_revertsOnZeroFeedId() public {
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](1);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: bytes32(0), chainlinkFeed: address(chainlink), heartbeat: 3600, set: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("pythFeedId"))
        );
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    function test_constructor_revertsOnDuplicateAsset() public {
        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WETH;
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](2);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(chainlink), heartbeat: 3600, set: false
        });
        configs[1] = configs[0];
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("duplicate")));
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    /// @dev A well-formed single-asset config array, mutated per test to trip one guard.
    function _oneConfig(address feed, bytes32 feedId, uint32 heartbeat)
        internal
        pure
        returns (address[] memory assets, PythChainlinkOracle.FeedConfig[] memory configs)
    {
        assets = new address[](1);
        assets[0] = WETH;
        configs = new PythChainlinkOracle.FeedConfig[](1);
        configs[0] =
            PythChainlinkOracle.FeedConfig({pythFeedId: feedId, chainlinkFeed: feed, heartbeat: heartbeat, set: false});
    }

    function test_constructor_revertsOnZeroStaleness() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) =
            _oneConfig(address(chainlink), WETH_FEED_ID, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("maxStaleness"))
        );
        new PythChainlinkOracle(address(pyth), 0, MAX_CONF_BPS, MAX_DEV_BPS, a, c);
    }

    function test_constructor_revertsOnConfOutOfRange() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) =
            _oneConfig(address(chainlink), WETH_FEED_ID, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("maxConfidenceBps"))
        );
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, 10_000, MAX_DEV_BPS, a, c);
    }

    function test_constructor_revertsOnDeviationOutOfRange() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) =
            _oneConfig(address(chainlink), WETH_FEED_ID, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("maxDeviationBps"))
        );
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, 0, a, c);
    }

    function test_constructor_revertsOnZeroChainlinkFeed() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) = _oneConfig(address(0), WETH_FEED_ID, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("chainlinkFeed"))
        );
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, a, c);
    }

    function test_constructor_revertsOnZeroHeartbeat() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) =
            _oneConfig(address(chainlink), WETH_FEED_ID, 0);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("heartbeat")));
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, a, c);
    }

    function test_constructor_revertsOnZeroAsset() public {
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) =
            _oneConfig(address(chainlink), WETH_FEED_ID, 3600);
        a[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("asset")));
        new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, a, c);
    }

    /*//////////////////////////////////////////////////////////////
                          MISC COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revertsOnAnchorOver18Decimals() public {
        // A malformed feed reporting more than 18 decimals cannot be normalized; the read reverts.
        MockChainlinkFeed bad = new MockChainlinkFeed(20, 2000e20, block.timestamp);
        (address[] memory a, PythChainlinkOracle.FeedConfig[] memory c) = _oneConfig(address(bad), WETH_FEED_ID, 3600);
        PythChainlinkOracle o = new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, a, c);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InvalidConfiguration.selector, bytes32("decimals")));
        o.getPrice(WETH);
    }

    function test_getFeedConfig_returnsWiring() public view {
        PythChainlinkOracle.FeedConfig memory config = oracle.getFeedConfig(WETH);
        assertEq(config.pythFeedId, WETH_FEED_ID, "feed id");
        assertEq(config.chainlinkFeed, address(chainlink), "anchor");
        assertEq(config.heartbeat, uint32(3600), "heartbeat");
        assertTrue(config.set, "set flag");
    }

    receive() external payable {}
}
