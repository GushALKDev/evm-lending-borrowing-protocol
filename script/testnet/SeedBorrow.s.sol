// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {DemoPyth} from "./DemoPyth.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {TestnetPrices} from "./TestnetPrices.sol";

/**
 * @title SeedBorrow
 * @notice Opens the demo market's seed borrow, so the market starts at about 50% utilization with
 *         non-zero rates instead of an idle one: the deployer posts SEED_COLLATERAL WETH and borrows
 *         SEED_BORROW USDC against the liquidity DeployTestnet supplied.
 * @dev Run with the same key as DeployTestnet, which owns the faucet, right after it. A separate run on
 *      purpose: the borrow carries a price published at the simulated block, and the oracle rejects it
 *      once it is older than 60 seconds, so it should not wait behind a dozen deployment transactions.
 *      If it reverts with StalePrice anyway (a slow RPC), run it again.
 *
 *      At an ETH price of $4,000 the borrow uses about 39% of its capacity, and at Chainlink prices it
 *      becomes absorbable only below about $1,470.
 *
 *      Usage: forge script script/testnet/SeedBorrow.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
 *               --account <keystore> --broadcast
 *      Reads the addresses from DEPLOYMENT_FILE, or app/src/config/deployments/<chainId>.json.
 */
contract SeedBorrow is Script, TestnetPrices {
    uint256 internal constant SEED_COLLATERAL = 200e18;
    uint256 internal constant SEED_BORROW = 250_000e6;

    /// @notice The contracts the seed borrow touches.
    struct Target {
        LendingMarket market;
        TestnetFaucet faucet;
        DemoPyth pyth;
        address[3] feeds; // USDC, WETH, WBTC Chainlink anchors
    }

    function run() external {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", defaultPath));
        Target memory t = Target({
            market: LendingMarket(payable(vm.parseJsonAddress(json, ".market"))),
            faucet: TestnetFaucet(vm.parseJsonAddress(json, ".faucet")),
            pyth: DemoPyth(vm.parseJsonAddress(json, ".pyth")),
            feeds: [
                vm.parseJsonAddress(json, ".USDC.chainlinkFeed"),
                vm.parseJsonAddress(json, ".WETH.chainlinkFeed"),
                vm.parseJsonAddress(json, ".WBTC.chainlinkFeed")
            ]
        });
        seed(t);
    }

    /// @notice Posts the collateral and opens the borrow, broadcasting from the faucet owner.
    function seed(Target memory t) public {
        address usdc = address(t.faucet.USDC());
        address weth = address(t.faucet.WETH());

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        t.faucet.mint(weth, deployer, SEED_COLLATERAL);
        IERC20(weth).approve(address(t.market), SEED_COLLATERAL);
        t.market.supply(weth, SEED_COLLATERAL);

        // Priced the way the app prices every borrow; the market reads the base and WETH, so two oracle
        // calls pay for the three entries each, and the unspent third is refunded.
        bytes[] memory update = _mirrorAll(t.pyth, t.feeds);
        t.market.withdraw{value: 3 * t.pyth.getUpdateFee(update)}(usdc, SEED_BORROW, update);

        vm.stopBroadcast();
    }
}
