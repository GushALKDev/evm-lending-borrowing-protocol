// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployTestnet} from "../DeployTestnet.s.sol";
import {SeedBorrow} from "../SeedBorrow.s.sol";
import {DemoPyth} from "../DemoPyth.sol";
import {TestnetFaucet} from "../TestnetFaucet.sol";
import {LendingMarket} from "../../../src/LendingMarket.sol";
import {InterestRateModel} from "../../../src/InterestRateModel.sol";
import {PythChainlinkOracle} from "../../../src/PythChainlinkOracle.sol";
import {MockChainlinkFeed} from "../../../test/mocks/MockChainlinkFeed.sol";

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol and SeedBorrow.s.sol against mock Chainlink feeds, then drives
 *         the market the way the demo app does: mirror the Chainlink answers into DemoPyth inside the
 *         same call that needs them, and pay the update fee.
 * @dev Run with FOUNDRY_PROFILE=testnet. Outside a broadcast the deploy script writes no file.
 */
contract DeployTestnetTest is Test {
    bytes32 internal constant USDC_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant BTC_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    address internal constant BORROWER = address(0xB0B);
    address internal constant GRIEFER = address(0xBAD);

    MockChainlinkFeed internal usdcFeed;
    MockChainlinkFeed internal wethFeed;
    MockChainlinkFeed internal wbtcFeed;

    DeployTestnet internal script;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdcFeed = new MockChainlinkFeed(8, 1e8, block.timestamp);
        wethFeed = new MockChainlinkFeed(8, 4_000e8, block.timestamp);
        wbtcFeed = new MockChainlinkFeed(8, 100_000e8, block.timestamp);

        vm.setEnv("USDC_CL_FEED", vm.toString(address(usdcFeed)));
        vm.setEnv("WETH_CL_FEED", vm.toString(address(wethFeed)));
        vm.setEnv("WBTC_CL_FEED", vm.toString(address(wbtcFeed)));

        script = new DeployTestnet();
    }

    /// @dev Deploys, then opens the seed borrow, as the two scripts do on Base Sepolia.
    function _deploy()
        internal
        returns (LendingMarket market, PythChainlinkOracle oracle, DemoPyth pyth, TestnetFaucet faucet)
    {
        InterestRateModel irm;
        (market, irm, oracle) = script.run();
        (faucet, pyth,) = script.deployment();
        assertEq(address(market.INTEREST_RATE_MODEL()), address(irm), "rate model wired");

        SeedBorrow seeder = new SeedBorrow();
        seeder.seed(
            SeedBorrow.Target({
                market: market,
                faucet: faucet,
                pyth: pyth,
                feeds: [address(usdcFeed), address(wethFeed), address(wbtcFeed)]
            })
        );
    }

    /// @dev What the app sends: each Chainlink answer with 5 bps of confidence, published now.
    function _appUpdate(DemoPyth pyth) internal view returns (bytes[] memory update) {
        update = new bytes[](3);
        update[0] = _entry(pyth, USDC_ID, usdcFeed);
        update[1] = _entry(pyth, ETH_ID, wethFeed);
        update[2] = _entry(pyth, BTC_ID, wbtcFeed);
    }

    function _entry(DemoPyth pyth, bytes32 id, MockChainlinkFeed feed) internal view returns (bytes memory) {
        (, int256 answer,,,) = feed.latestRoundData();
        return pyth.createPriceFeedUpdateData(
            id, int64(answer), uint64(uint256(answer) * 5 / 10_000), -8, uint64(block.timestamp)
        );
    }

    function _postCollateral(LendingMarket market, TestnetFaucet faucet) internal {
        vm.startPrank(BORROWER);
        faucet.claim();
        IERC20(address(faucet.WETH())).approve(address(market), 5e18);
        market.supply(address(faucet.WETH()), 5e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 30);
        vm.deal(BORROWER, 1 ether);
    }

    function test_run_deploysTheMarketWithTestnetTokensAndSeedsLiquidity() public {
        (LendingMarket market, PythChainlinkOracle oracle, DemoPyth pyth, TestnetFaucet faucet) = _deploy();

        assertEq(market.BASE_TOKEN(), address(faucet.USDC()), "USDC base");
        assertEq(address(oracle.PYTH()), address(pyth), "oracle reads DemoPyth");
        assertEq(oracle.MAX_STALENESS(), 60, "same staleness as Deploy.s.sol");
        assertEq(oracle.MAX_CONFIDENCE_BPS(), 200, "same confidence cap");
        assertEq(oracle.MAX_DEVIATION_BPS(), 300, "same deviation cap");
        assertEq(oracle.getFeedConfig(address(faucet.WETH())).chainlinkFeed, address(wethFeed), "WETH anchor");

        // Liquidity sits with the faucet contract, which has no way to withdraw it.
        assertEq(market.balanceOf(address(faucet)), 500_000e6, "seed liquidity owned by the faucet");
        assertEq(market.totalSupply(), 500_000e6, "seeded supply");
        // The seed borrow opens the demo at 78% utilization.
        assertEq(market.totalBorrow(), 390_000e6, "seed borrow");
        assertEq(market.getUtilization(), 0.78e18, "78% utilization");
        assertEq(IERC20(address(faucet.USDC())).balanceOf(address(market)), 110_000e6, "cash left to borrow");

        (uint256 ethPrice,) = oracle.getPrice(address(faucet.WETH()));
        assertEq(ethPrice, 4_000e18, "mirrored ETH price");
    }

    /// @dev The smoke test is the only guard on the wBTC anchor: nothing else in the run prices wBTC.
    function test_run_revertsBeforeBroadcastingWhenAnAnchorIsStale() public {
        wbtcFeed.setAnswer(100_000e8, block.timestamp - 3_601);
        // The asset address is only known inside the run, so match on the selector.
        try script.run() {
            assertTrue(false, "expected a stale anchor revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), PythChainlinkOracle.StaleAnchor.selector, "stale anchor");
        }
    }

    function test_appFlow_borrowWithMirroredPrices() public {
        (LendingMarket market,, DemoPyth pyth, TestnetFaucet faucet) = _deploy();
        _postCollateral(market, faucet);

        // Base plus one collateral: two oracle calls, each paying for the three entries. The update is
        // built before the prank, which would otherwise apply to the feed reads.
        bytes[] memory update = _appUpdate(pyth);
        address usdc = address(faucet.USDC());
        vm.prank(BORROWER);
        market.withdraw{value: 10 wei}(usdc, 10_000e6, update);

        // The seed borrow has already grown the borrow index, so the new debt rounds up by at most a wei.
        uint256 debt = market.borrowBalanceOf(BORROWER);
        assertGe(debt, 10_000e6, "borrowed");
        assertLe(debt, 10_000e6 + 1, "rounded up by at most one wei");
        assertEq(BORROWER.balance, 1 ether - 6 wei, "only the fee was kept");
    }

    function test_appFlow_aForgedPriceOutsideTheAnchorBandReverts() public {
        (LendingMarket market,, DemoPyth pyth, TestnetFaucet faucet) = _deploy();
        _postCollateral(market, faucet);

        // ETH pushed 5% above its Chainlink anchor: the 300 bps deviation check rejects it.
        bytes[] memory update = _appUpdate(pyth);
        update[1] = pyth.createPriceFeedUpdateData(ETH_ID, 4_200e8, 2e8, -8, uint64(block.timestamp));
        address weth = address(faucet.WETH());
        address usdc = address(faucet.USDC());
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.PriceDeviationTooHigh.selector, weth, 500, 300));
        market.withdraw{value: 10 wei}(usdc, 10_000e6, update);
    }

    /// @dev Regression guard for the griefing fix: a price pushed earlier in the same block, with the same
    ///      publishTime the app uses, must not be what the app's call reads.
    function test_appFlow_aGriefersEarlierPushIsOverwrittenByTheAppsUpdate() public {
        (LendingMarket market,, DemoPyth pyth, TestnetFaucet faucet) = _deploy();
        _postCollateral(market, faucet);

        bytes[] memory forged = _appUpdate(pyth);
        forged[1] = pyth.createPriceFeedUpdateData(ETH_ID, 4_200e8, 2e8, -8, uint64(block.timestamp));
        vm.deal(GRIEFER, 1 ether);
        vm.prank(GRIEFER);
        pyth.updatePriceFeeds{value: 3}(forged);

        bytes[] memory update = _appUpdate(pyth);
        address usdc = address(faucet.USDC());
        vm.prank(BORROWER);
        market.withdraw{value: 10 wei}(usdc, 10_000e6, update);
        assertGe(market.borrowBalanceOf(BORROWER), 10_000e6, "the app's own update was the one read");
    }
}
