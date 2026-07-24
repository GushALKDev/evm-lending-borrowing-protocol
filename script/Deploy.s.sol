// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {ILendingMarket} from "../src/interfaces/ILendingMarket.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {PythChainlinkOracle} from "../src/PythChainlinkOracle.sol";

/**
 * @title Deploy
 * @notice Immutable deployment of the full market: rate model, oracle, and the market itself, wired
 *         for a USDC base with WETH and wBTC collateral.
 * @dev Every external address (tokens, Pyth, Chainlink feeds) and every Pyth feed id is read from the
 *      environment with a zero/placeholder default, so the script runs on a local node out of the box
 *      and takes real addresses on a testnet or fork by exporting the vars. The reference risk and
 *      curve parameters come from Guide 2, Section 11. Nothing here is mutable post-deployment.
 */
contract Deploy is Script {
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @dev Resolved external addresses, grouped to keep run() within the stack limit.
    struct Wiring {
        address owner;
        address guardian;
        address usdc;
        address weth;
        address wbtc;
        address pyth;
    }

    function run() external returns (LendingMarket market, InterestRateModel irm, PythChainlinkOracle oracle) {
        Wiring memory w = _wiring();

        vm.startBroadcast();
        irm = _deployRateModel();
        oracle = _deployOracle(w);
        market = _deployMarket(w, irm, oracle);
        vm.stopBroadcast();

        // solhint-disable-next-line no-console
        console2.log("InterestRateModel:", address(irm));
        // solhint-disable-next-line no-console
        console2.log("PythChainlinkOracle:", address(oracle));
        // solhint-disable-next-line no-console
        console2.log("Market:", address(market));
    }

    function _wiring() internal view returns (Wiring memory w) {
        w.owner = vm.envOr("OWNER", msg.sender);
        w.guardian = vm.envOr("GUARDIAN", msg.sender);
        w.usdc = vm.envOr("USDC", address(0x1));
        w.weth = vm.envOr("WETH", address(0x2));
        w.wbtc = vm.envOr("WBTC", address(0x3));
        w.pyth = vm.envOr("PYTH", address(0x4));
    }

    /// @dev Reference curve (Guide 2, Section 11): base 0, 4% APR at the 80% kink, 100%/year jump, 10% RF.
    function _deployRateModel() internal returns (InterestRateModel) {
        return new InterestRateModel((0), (0.05e18) / SECONDS_PER_YEAR, (1e18) / SECONDS_PER_YEAR, 0.8e18, 0.1e18);
    }

    /// @dev Pyth primary + Chainlink anchor, reference thresholds (60s staleness, 200/300 bps caps).
    function _deployOracle(Wiring memory w) internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](3);
        assets[0] = w.usdc;
        assets[1] = w.weth;
        assets[2] = w.wbtc;

        PythChainlinkOracle.FeedConfig[] memory feeds = new PythChainlinkOracle.FeedConfig[](3);
        feeds[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: vm.envOr("USDC_PYTH_ID", bytes32(uint256(0x21))),
            chainlinkFeed: vm.envOr("USDC_CL_FEED", address(0x11)),
            heartbeat: 86_400,
            set: true
        });
        feeds[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: vm.envOr("WETH_PYTH_ID", bytes32(uint256(0x22))),
            chainlinkFeed: vm.envOr("WETH_CL_FEED", address(0x12)),
            heartbeat: 3_600,
            set: true
        });
        feeds[2] = PythChainlinkOracle.FeedConfig({
            pythFeedId: vm.envOr("WBTC_PYTH_ID", bytes32(uint256(0x23))),
            chainlinkFeed: vm.envOr("WBTC_CL_FEED", address(0x13)),
            heartbeat: 3_600,
            set: true
        });

        return new PythChainlinkOracle(w.pyth, 60, 200, 300, assets, feeds);
    }

    /// @dev USDC base, WETH + wBTC collateral. liquidationFactor satisfies INV-13:
    ///      >= liquidateCF * (1 + maxConfidenceBps), e.g. 85% * 1.02 = 86.7% <= 93%.
    function _deployMarket(Wiring memory w, InterestRateModel irm, PythChainlinkOracle oracle)
        internal
        returns (LendingMarket)
    {
        LendingMarket.MarketConfig memory cfg = LendingMarket.MarketConfig({
            baseToken: w.usdc,
            interestRateModel: address(irm),
            oracle: address(oracle),
            owner: w.owner,
            guardian: w.guardian,
            minBorrow: 100e6,
            targetReserves: 1_000_000e6
        });

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](2);
        collaterals[0] = ILendingMarket.CollateralConfig({
            asset: w.weth,
            borrowCollateralFactor: 8_000,
            liquidateCollateralFactor: 8_500,
            liquidationFactor: 9_300,
            storeFrontPriceFactor: 5_000,
            supplyCap: 10_000e18,
            decimals: 18
        });
        collaterals[1] = ILendingMarket.CollateralConfig({
            asset: w.wbtc,
            borrowCollateralFactor: 7_500,
            liquidateCollateralFactor: 8_000,
            liquidationFactor: 9_000,
            storeFrontPriceFactor: 5_000,
            supplyCap: 500e8,
            decimals: 8
        });

        return new LendingMarket(cfg, collaterals);
    }
}
