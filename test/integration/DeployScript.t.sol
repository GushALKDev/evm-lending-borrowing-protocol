// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title DeployScriptTest
 * @notice Phase 8 item 8.6, second half: a rehearsal of Deploy.s.sol. The script reads every external
 *         address and feed id from the environment; against real deployed dependencies (mock tokens,
 *         a real MockPyth, real Chainlink aggregators) exported into those vars, run() must deploy the
 *         rate model, oracle, and market and wire them together without reverting.
 * @dev This is what "deployment script rehearsal on anvil" reduces to in a reproducible CI test: the
 *      script's own default placeholder addresses have no code, so the market constructor's
 *      IERC20Metadata(decimals) call reverts on a bare dry run. Exporting real contract addresses is
 *      exactly the step an operator performs before broadcasting to a live network.
 */
contract DeployScriptTest is Test {
    function test_deployScript_wiresTheMarketAgainstRealDependencies() public {
        // Deploy the external dependencies the script expects, with the reference decimals.
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockPyth pyth = new MockPyth(365 days, 1 wei);
        MockChainlinkFeed usdcFeed = new MockChainlinkFeed(8, 1e8, block.timestamp);
        MockChainlinkFeed wethFeed = new MockChainlinkFeed(8, 2_000e8, block.timestamp);
        MockChainlinkFeed wbtcFeed = new MockChainlinkFeed(8, 60_000e8, block.timestamp);

        // Export the addresses the script reads via vm.envOr. Feed ids keep the script defaults.
        vm.setEnv("USDC", vm.toString(address(usdc)));
        vm.setEnv("WETH", vm.toString(address(weth)));
        vm.setEnv("WBTC", vm.toString(address(wbtc)));
        vm.setEnv("PYTH", vm.toString(address(pyth)));
        vm.setEnv("USDC_CL_FEED", vm.toString(address(usdcFeed)));
        vm.setEnv("WETH_CL_FEED", vm.toString(address(wethFeed)));
        vm.setEnv("WBTC_CL_FEED", vm.toString(address(wbtcFeed)));

        Deploy deployer = new Deploy();
        (LendingMarket market, InterestRateModel irm, PythChainlinkOracle oracle) = deployer.run();

        // Everything deployed and non-zero.
        assertTrue(address(market) != address(0), "market deployed");
        assertTrue(address(irm) != address(0), "rate model deployed");
        assertTrue(address(oracle) != address(0), "oracle deployed");

        // The market points at the rate model and oracle the script deployed.
        assertEq(address(market.INTEREST_RATE_MODEL()), address(irm), "IRM wired");
        assertEq(address(market.ORACLE()), address(oracle), "oracle wired");
        assertEq(market.BASE_TOKEN(), address(usdc), "USDC base wired");

        // Both collaterals are listed: getCollateralReserves calls _requireListed and would revert
        // on an unlisted asset, so a clean read proves the script registered them.
        assertEq(market.getCollateralReserves(address(weth)), 0, "WETH listed, empty inventory");
        assertEq(market.getCollateralReserves(address(wbtc)), 0, "WBTC listed, empty inventory");

        // The market accrues cleanly at genesis: the wired rate model and index seed are consistent.
        market.accrue();
        assertEq(market.getUtilization(), 0, "no utilization at genesis");
    }
}
