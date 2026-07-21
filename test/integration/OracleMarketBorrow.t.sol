// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title OracleMarketBorrowTest
 * @notice Phase 5 item 5.8: the real PythChainlinkOracle wired into a real market, driving a full
 *         borrow. Proves the market's per-asset "forward the whole balance" fee pattern works against
 *         the real fee/refund logic (not just the mock), and that a collateralized borrow succeeds
 *         while the market ends holding no ETH.
 */
contract OracleMarketBorrowTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal usdcAnchor;
    MockChainlinkFeed internal wethAnchor;
    PythChainlinkOracle internal oracle;

    LendingMarketHarness internal market;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal lp = makeAddr("lp");

    bytes32 internal constant USDC_FEED_ID = keccak256("USDC/USD");
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");

    uint256 internal constant FEE = 1 wei;
    int32 internal constant EXPO = -8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);

        pyth = new MockPyth(365 days, FEE);
        usdcAnchor = new MockChainlinkFeed(8, 1e8, block.timestamp);
        wethAnchor = new MockChainlinkFeed(8, 2000e8, block.timestamp);
        oracle = _deployOracle();

        // Seed both Pyth feeds fresh.
        _pushBoth();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(usdc), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        market = new LendingMarketHarness(cfg, collaterals);

        // LP funds the base so there is cash to borrow.
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(market), type(uint256).max);
        market.supply(address(usdc), 1_000_000e6);
        vm.stopPrank();

        // Alice deposits 10 WETH collateral.
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), 10e18);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
    }

    function _deployOracle() internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](2);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: USDC_FEED_ID, chainlinkFeed: address(usdcAnchor), heartbeat: 86_400, set: false
        });
        configs[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(wethAnchor), heartbeat: 3_600, set: false
        });
        return new PythChainlinkOracle(address(pyth), 60, 200, 300, assets, configs);
    }

    /// @dev Builds and pushes a two-feed update blob (USDC $1, WETH $2000) at the current time.
    function _pushBoth() internal {
        bytes[] memory update = _blob();
        pyth.updatePriceFeeds{value: FEE * update.length}(update);
    }

    function _blob() internal view returns (bytes[] memory update) {
        update = new bytes[](2);
        update[0] = pyth.createPriceFeedUpdateData(USDC_FEED_ID, 1e8, 0, EXPO, 1e8, 0, uint64(block.timestamp));
        update[1] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, 2000e8, 2e8, EXPO, 2000e8, 2e8, uint64(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                               THE FLOW
    //////////////////////////////////////////////////////////////*/

    function test_borrowAgainstRealOracle_succeedsAndRefunds() public {
        // 10 WETH * $2000 * 80% borrowCF = $16,000 capacity. Borrow 10,000 USDC, well within.
        bytes[] memory update = _blob();

        uint256 aliceEthBefore = alice.balance;
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Overfund: the market forwards its whole balance per asset; the oracle consumes only the
        // Pyth fee per call and refunds the rest, so the surplus ends back with alice.
        vm.prank(alice);
        market.withdraw{value: 0.5 ether}(address(usdc), 10_000e6, update);

        assertEq(usdc.balanceOf(alice) - usdcBefore, 10_000e6, "borrowed base received");
        assertEq(market.borrowBalanceOf(alice), 10_000e6, "debt recorded");

        // Two feeds pushed twice (base call + weth call), FEE per feed = 4 wei consumed total.
        uint256 spent = aliceEthBefore - alice.balance;
        assertEq(spent, FEE * 4, "only the pyth fee is consumed, surplus refunded");
        assertEq(address(market).balance, 0, "market holds no ETH");
        assertEq(address(oracle).balance, 0, "oracle holds no ETH");
    }

    function test_borrowRevertsWhenUnderfunded() public {
        bytes[] memory update = _blob();
        // Not enough to cover even the first per-asset Pyth fee.
        vm.prank(alice);
        vm.expectRevert();
        market.withdraw{value: 0}(address(usdc), 10_000e6, update);
    }
}
