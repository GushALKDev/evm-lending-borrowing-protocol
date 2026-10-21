// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy} from "../Deploy.s.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {DemoPyth} from "./DemoPyth.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {TestnetPrices} from "./TestnetPrices.sol";

/**
 * @title DeployTestnet
 * @notice Public testnet deployment of the demo market (Base Sepolia by default): testnet tokens with a
 *         faucet, DemoPyth in place of Pyth, the real Chainlink feeds of the chain as anchors, and the
 *         same rate model, oracle thresholds and market parameters as Deploy.s.sol.
 * @dev What differs from Deploy.s.sol, and why:
 *      - Tokens: TestnetFaucet deploys USDC, WETH and wBTC stand-ins with the real decimals.
 *      - Pyth: DemoPyth, because Hermes needs a paid API key. The app mirrors the Chainlink answer
 *        into it in every price-dependent call (see DemoPyth for what that does and does not check).
 *      - Anchor heartbeats: the Base Sepolia feeds update ETH/USD and BTC/USD at least every 1,200 s
 *        and USDC/USD every 86,400 s. The windows below add a margin over each, so an update that lands
 *        a few seconds late does not make the anchor read as stale.
 *      - Liquidity: the deployer supplies SEED_LIQUIDITY USDC on behalf of the faucet contract, which has
 *        no function to withdraw it, so that liquidity stays in the market for good.
 *      Before anything is sent, the script mirrors the live Chainlink answers into DemoPyth and reads
 *      every price through the oracle, in simulation only: a stale or missing feed reverts the run. On a
 *      broadcast it also writes the deployment file the app reads. SeedBorrow.s.sol then opens the seed
 *      borrow, as a separate run because it needs a price no older than 60 seconds when it lands.
 *
 *      Usage (Base Sepolia):
 *        forge script script/testnet/DeployTestnet.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
 *          --account <keystore> --broadcast
 *      Optional env: OWNER, GUARDIAN, USDC_CL_FEED, WETH_CL_FEED, WBTC_CL_FEED, DEPLOYMENT_FILE.
 */
contract DeployTestnet is Deploy, TestnetPrices {
    /// @dev Chainlink feeds on Base Sepolia (Chainlink data feed directory, checked 21 Oct 2026).
    address internal constant BASE_SEPOLIA_USDC_USD = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address internal constant BASE_SEPOLIA_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant BASE_SEPOLIA_BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    /// @dev Anchor staleness windows: feed heartbeat plus margin (see the contract notes).
    uint32 internal constant USDC_ANCHOR_HEARTBEAT = 90_000;
    uint32 internal constant VOLATILE_ANCHOR_HEARTBEAT = 3_600;

    /// @dev Oracle thresholds, identical to Deploy.s.sol.
    uint256 internal constant MAX_STALENESS = 60;
    uint256 internal constant MAX_CONFIDENCE_BPS = 200;
    uint256 internal constant MAX_DEVIATION_BPS = 300;

    /// @dev DemoPyth fee per update entry.
    uint256 internal constant DEMO_UPDATE_FEE = 1 wei;

    /// @dev USDC supplied on behalf of the faucet contract.
    uint256 internal constant SEED_LIQUIDITY = 500_000e6;

    /// @notice Everything the testnet run deploys, besides the three contracts run() returns.
    struct TestnetDeployment {
        TestnetFaucet faucet;
        DemoPyth pyth;
        address[3] feeds; // USDC, WETH, WBTC Chainlink anchors
        uint256 deployBlock;
    }

    /// @notice The extra contracts of the last run, for tests and the deployment file.
    TestnetDeployment public deployment;

    function run() external override returns (LendingMarket market, InterestRateModel irm, PythChainlinkOracle oracle) {
        address[3] memory feeds = _feeds();
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        TestnetFaucet faucet = new TestnetFaucet(deployer);
        DemoPyth pyth = new DemoPyth(DEMO_UPDATE_FEE);

        Wiring memory w = Wiring({
            owner: vm.envOr("OWNER", deployer),
            guardian: vm.envOr("GUARDIAN", deployer),
            usdc: address(faucet.USDC()),
            weth: address(faucet.WETH()),
            wbtc: address(faucet.WBTC()),
            pyth: address(pyth)
        });

        irm = _deployRateModel();
        oracle = _deployTestnetOracle(w, feeds);
        market = _deployMarket(w, irm, oracle);

        // Liquidity owned by the faucet contract, which cannot withdraw it.
        faucet.mint(w.usdc, deployer, SEED_LIQUIDITY);
        IERC20(w.usdc).approve(address(market), SEED_LIQUIDITY);
        market.supplyTo(address(faucet), w.usdc, SEED_LIQUIDITY);

        vm.stopBroadcast();

        deployment = TestnetDeployment({faucet: faucet, pyth: pyth, feeds: feeds, deployBlock: deployBlock});

        _smokeTest(w, oracle, pyth, feeds);

        // Only on a real broadcast: a dry run must not overwrite the file with addresses never deployed.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeDeployment(w, market, irm, oracle);

        // solhint-disable-next-line no-console
        console2.log("Market:", address(market));
        // solhint-disable-next-line no-console
        console2.log("Faucet:", address(faucet));
    }

    /// @dev Base Sepolia feeds by default; any other chain must export all three.
    function _feeds() internal view returns (address[3] memory feeds) {
        bool baseSepolia = block.chainid == BASE_SEPOLIA_CHAIN_ID;
        feeds[0] = baseSepolia ? vm.envOr("USDC_CL_FEED", BASE_SEPOLIA_USDC_USD) : vm.envAddress("USDC_CL_FEED");
        feeds[1] = baseSepolia ? vm.envOr("WETH_CL_FEED", BASE_SEPOLIA_ETH_USD) : vm.envAddress("WETH_CL_FEED");
        feeds[2] = baseSepolia ? vm.envOr("WBTC_CL_FEED", BASE_SEPOLIA_BTC_USD) : vm.envAddress("WBTC_CL_FEED");
    }

    /// @dev Same thresholds as Deploy._deployOracle; only the anchors and their heartbeats differ.
    function _deployTestnetOracle(Wiring memory w, address[3] memory feeds) internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](3);
        assets[0] = w.usdc;
        assets[1] = w.weth;
        assets[2] = w.wbtc;

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](3);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: USDC_USD_FEED_ID, chainlinkFeed: feeds[0], heartbeat: USDC_ANCHOR_HEARTBEAT, set: true
        });
        configs[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: ETH_USD_FEED_ID, chainlinkFeed: feeds[1], heartbeat: VOLATILE_ANCHOR_HEARTBEAT, set: true
        });
        configs[2] = PythChainlinkOracle.FeedConfig({
            pythFeedId: BTC_USD_FEED_ID, chainlinkFeed: feeds[2], heartbeat: VOLATILE_ANCHOR_HEARTBEAT, set: true
        });

        return new PythChainlinkOracle(w.pyth, MAX_STALENESS, MAX_CONFIDENCE_BPS, MAX_DEVIATION_BPS, assets, configs);
    }

    /**
     * @dev Simulation only, after stopBroadcast: mirrors the live Chainlink answers into DemoPyth the
     *      way the app does, then reads every price through the oracle's full validation pipeline.
     */
    function _smokeTest(Wiring memory w, PythChainlinkOracle oracle, DemoPyth pyth, address[3] memory feeds) internal {
        bytes[] memory update = _mirrorAll(pyth, feeds);

        // A throwaway sender: forge rejects scripts that rely on their own ephemeral address.
        address smoke = makeAddr("DeployTestnet smoke test");
        uint256 fee = pyth.getUpdateFee(update);
        vm.deal(smoke, fee);
        vm.prank(smoke);
        pyth.updatePriceFeeds{value: fee}(update);

        oracle.getPrice(w.usdc);
        oracle.getPrice(w.weth);
        oracle.getPrice(w.wbtc);
    }

    /// @dev Writes the addresses and parameters the app needs to app/src/config/deployments/<chainId>.json.
    function _writeDeployment(Wiring memory w, LendingMarket market, InterestRateModel irm, PythChainlinkOracle oracle)
        internal
    {
        ILendingMarket.CollateralConfig[] memory collaterals = _collateralConfigs(w.weth, w.wbtc);

        string memory base = "base";
        vm.serializeAddress(base, "address", w.usdc);
        vm.serializeAddress(base, "chainlinkFeed", deployment.feeds[0]);
        vm.serializeBytes32(base, "pythFeedId", USDC_USD_FEED_ID);
        base = vm.serializeUint(base, "anchorHeartbeat", USDC_ANCHOR_HEARTBEAT);

        string memory weth = _collateralJson("weth", collaterals[0], deployment.feeds[1], ETH_USD_FEED_ID);
        string memory wbtc = _collateralJson("wbtc", collaterals[1], deployment.feeds[2], BTC_USD_FEED_ID);

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", deployment.deployBlock);
        vm.serializeAddress(root, "market", address(market));
        vm.serializeAddress(root, "rateModel", address(irm));
        vm.serializeAddress(root, "oracle", address(oracle));
        vm.serializeAddress(root, "pyth", address(deployment.pyth));
        vm.serializeAddress(root, "faucet", address(deployment.faucet));
        vm.serializeUint(root, "demoConfBps", DEMO_CONF_BPS);
        vm.serializeString(root, "USDC", base);
        vm.serializeString(root, "WETH", weth);
        root = vm.serializeString(root, "WBTC", wbtc);

        vm.writeJson(root, deploymentFile());
    }

    /// @notice Where the deployment file lives: DEPLOYMENT_FILE, or the app's file for this chain id.
    function deploymentFile() public view returns (string memory) {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        return vm.envOr("DEPLOYMENT_FILE", defaultPath);
    }

    function _collateralJson(
        string memory key,
        ILendingMarket.CollateralConfig memory c,
        address feed,
        bytes32 pythFeedId
    ) internal returns (string memory) {
        vm.serializeAddress(key, "address", c.asset);
        vm.serializeAddress(key, "chainlinkFeed", feed);
        vm.serializeBytes32(key, "pythFeedId", pythFeedId);
        vm.serializeUint(key, "anchorHeartbeat", VOLATILE_ANCHOR_HEARTBEAT);
        vm.serializeUint(key, "borrowCollateralFactor", c.borrowCollateralFactor);
        vm.serializeUint(key, "liquidateCollateralFactor", c.liquidateCollateralFactor);
        vm.serializeUint(key, "liquidationFactor", c.liquidationFactor);
        vm.serializeUint(key, "storeFrontPriceFactor", c.storeFrontPriceFactor);
        // As a string: 10_000e18 does not fit a JavaScript number exactly.
        vm.serializeString(key, "supplyCap", vm.toString(c.supplyCap));
        return vm.serializeUint(key, "decimals", c.decimals);
    }
}
