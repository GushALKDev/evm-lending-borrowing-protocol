// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title PythChainlinkOracleFuzzTest
 * @notice Fuzz coverage for the oracle: normalization to 1e18 across Pyth expos, and the confidence
 *         and deviation gates admitting exactly the values inside their thresholds.
 */
contract PythChainlinkOracleFuzzTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal chainlink;
    PythChainlinkOracle internal oracle;

    address internal constant WETH = address(0xE7);
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");

    uint256 internal constant MAX_STALENESS = 60;
    uint256 internal constant MAX_CONF_BPS = 200;
    uint256 internal constant MAX_DEV_BPS = 300;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE = 1 wei;

    function setUp() public {
        pyth = new MockPyth(365 days, FEE);
        // 18-decimal anchor so it can be set to the exact normalized price with no rounding drift.
        chainlink = new MockChainlinkFeed(18, 2000e18, block.timestamp);

        address[] memory assets = new address[](1);
        assets[0] = WETH;
        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](1);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(chainlink), heartbeat: 3600, set: false
        });
        oracle = new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONF_BPS, MAX_DEV_BPS, assets, configs);
    }

    function _push(int64 price, uint64 conf, int32 expo) internal {
        bytes[] memory update = new bytes[](1);
        update[0] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, price, conf, expo, price, conf, uint64(block.timestamp));
        pyth.updatePriceFeeds{value: FEE}(update);
    }

    /// @notice For any expo in [-18, 0], a Pyth mantissa normalizes to `mantissa * 10^(18+expo)`.
    function testFuzz_normalizesAcrossExpo(uint64 mantissa, int32 expo) public {
        mantissa = uint64(bound(mantissa, 1, 1e15));
        expo = int32(bound(int256(expo), -18, 0));

        // Anchor at the exact normalized value (18-dec feed) so no deviation triggers, conf 0.
        uint256 expected = uint256(mantissa) * (10 ** uint256(int256(18) + expo));
        chainlink.setAnswer(int256(expected), block.timestamp);

        _push(int64(mantissa), 0, expo);

        (uint256 price18, uint256 conf18) = oracle.getPrice(WETH);
        assertEq(price18, expected, "price normalized");
        assertEq(conf18, 0, "zero conf stays zero");
    }

    /// @notice The confidence gate accepts if and only if conf * 10,000 <= MAX_CONF_BPS * price, compared
    ///         exactly, and a rejection reports the ratio rounded up.
    /// @dev Half the runs draw conf from a window of [MAX - 1, MAX + 2] bps of the price, a third of which
    ///      lies strictly inside (MAX, MAX + 1) bps, where a floored ratio would pass. The other half draw
    ///      conf from the whole uint64 range. Expo stays in [-18, 0], where normalization is an
    ///      exact multiplication, so the comparison on the raw mantissas is the comparison the oracle makes.
    function testFuzz_confidenceGate(uint64 priceRaw, uint64 confRaw, int32 expo, bool nearLimit) public {
        uint256 price = bound(priceRaw, 1, uint64(type(int64).max));
        uint256 conf = nearLimit
            ? bound(confRaw, (price * (MAX_CONF_BPS - 1)) / BPS, (price * (MAX_CONF_BPS + 2)) / BPS)
            : uint256(confRaw);
        expo = int32(bound(int256(expo), -18, 0));

        uint256 scale = 10 ** uint256(int256(18) + expo);
        uint256 price18 = price * scale;
        uint256 conf18 = conf * scale;
        // 18-decimal anchor at the exact normalized price, so only the confidence can trip.
        chainlink.setAnswer(int256(price18), block.timestamp);
        _push(int64(uint64(price)), uint64(conf), expo);

        if (conf * BPS > MAX_CONF_BPS * price) {
            uint256 reportedBps = (conf18 * BPS + price18 - 1) / price18;
            vm.expectRevert(
                abi.encodeWithSelector(PythChainlinkOracle.ConfidenceTooWide.selector, WETH, reportedBps, MAX_CONF_BPS)
            );
            oracle.getPrice(WETH);
        } else {
            (uint256 gotPrice, uint256 gotConf) = oracle.getPrice(WETH);
            assertEq(gotPrice, price18, "in-band price accepted");
            assertEq(gotConf, conf18, "in-band conf accepted");
        }
    }

    /// @notice The deviation gate accepts if and only if |pyth - anchor| * 10,000 <= MAX_DEV_BPS * anchor,
    ///         compared exactly, and a rejection reports the ratio rounded up.
    /// @dev Half the runs place the anchor so the deviation falls in [MAX - 1, MAX + 2] bps, on either side
    ///      of the Pyth price, a third of which lies strictly inside (MAX, MAX + 1) bps. The other half draw
    ///      the anchor from [price / 2, price * 2].
    function testFuzz_deviationGate(uint64 priceRaw, uint256 anchorRaw, bool pythAbove, bool nearLimit) public {
        // $1 to $1,000,000 at expo -8, conf 0, so only the deviation can trip.
        uint256 price18 = bound(priceRaw, 1e8, 1e14) * 1e10;
        uint256 anchor18;
        if (!nearLimit) {
            anchor18 = bound(anchorRaw, price18 / 2, price18 * 2);
        } else if (pythAbove) {
            // price = anchor * (1 + d)  =>  anchor = price / (1 + d), d in [MAX - 1, MAX + 2] bps.
            anchor18 =
                bound(anchorRaw, (price18 * BPS) / (BPS + MAX_DEV_BPS + 2), (price18 * BPS) / (BPS + MAX_DEV_BPS - 1));
        } else {
            // price = anchor * (1 - d)  =>  anchor = price / (1 - d), d in [MAX - 1, MAX + 2] bps.
            anchor18 =
                bound(anchorRaw, (price18 * BPS) / (BPS - MAX_DEV_BPS + 1), (price18 * BPS) / (BPS - MAX_DEV_BPS - 2));
        }
        chainlink.setAnswer(int256(anchor18), block.timestamp);
        _push(int64(uint64(price18 / 1e10)), 0, -8);

        uint256 diff = price18 > anchor18 ? price18 - anchor18 : anchor18 - price18;
        if (diff * BPS > MAX_DEV_BPS * anchor18) {
            uint256 reportedBps = (diff * BPS + anchor18 - 1) / anchor18;
            vm.expectRevert(
                abi.encodeWithSelector(
                    PythChainlinkOracle.PriceDeviationTooHigh.selector, WETH, reportedBps, MAX_DEV_BPS
                )
            );
            oracle.getPrice(WETH);
        } else {
            (uint256 gotPrice,) = oracle.getPrice(WETH);
            assertEq(gotPrice, price18, "in-band deviation accepted");
        }
    }
}
