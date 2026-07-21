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

    /// @notice The confidence gate admits exactly conf/price ratios up to MAX_CONF_BPS and rejects above.
    function testFuzz_confidenceGate(uint64 confRaw) public {
        // price fixed at $2000 (2000e8, expo -8); anchor matches so only confidence can trip.
        uint64 conf = uint64(bound(confRaw, 0, 200e8)); // up to 1000 bps
        chainlink.setAnswer(2000e18, block.timestamp);
        _push(2000e8, conf, -8);

        uint256 confBps = (uint256(conf) * BPS) / 2000e8;
        if (confBps > MAX_CONF_BPS) {
            vm.expectRevert(
                abi.encodeWithSelector(PythChainlinkOracle.ConfidenceTooWide.selector, WETH, confBps, MAX_CONF_BPS)
            );
            oracle.getPrice(WETH);
        } else {
            (uint256 price18,) = oracle.getPrice(WETH);
            assertEq(price18, 2000e18, "in-band confidence accepted");
        }
    }

    /// @notice The deviation gate admits exactly |pyth-anchor|/anchor up to MAX_DEV_BPS and rejects above.
    function testFuzz_deviationGate(uint256 anchorPrice) public {
        // Pyth fixed at $2000, conf 0; vary the 18-dec anchor around it.
        uint256 anchor18 = bound(anchorPrice, 1800e18, 2200e18);
        chainlink.setAnswer(int256(anchor18), block.timestamp);
        _push(2000e8, 0, -8);

        uint256 pyth18 = 2000e18;
        uint256 diff = pyth18 > anchor18 ? pyth18 - anchor18 : anchor18 - pyth18;
        uint256 devBps = (diff * BPS) / anchor18;

        if (devBps > MAX_DEV_BPS) {
            vm.expectRevert(
                abi.encodeWithSelector(PythChainlinkOracle.PriceDeviationTooHigh.selector, WETH, devBps, MAX_DEV_BPS)
            );
            oracle.getPrice(WETH);
        } else {
            (uint256 price18,) = oracle.getPrice(WETH);
            assertEq(price18, pyth18, "in-band deviation accepted");
        }
    }
}
