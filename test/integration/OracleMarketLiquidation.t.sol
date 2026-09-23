// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title OracleMarketLiquidationTest
 * @notice Phase 8 item 8.10: absorb and buyCollateral driven through the real PythChainlinkOracle
 *         (over the SDK's fee-charging MockPyth and settable Chainlink anchors) on a production
 *         LendingMarket. The liquidation twin of OracleMarketBorrowTest: it proves the payable
 *         price-update path of both liquidation entry points, the per-asset "forward the whole
 *         balance" fee pattern, and the final sweep, against the real fee/refund logic.
 * @dev The mainnet fork suite cannot reach these paths (a cached VAA cannot move the price), and the
 *      unit, fuzz, and invariant layers price through MockPriceOracle, which charges no fee. Here the
 *      price drop is a fresh signed update, so every push pays the Pyth fee for real. Rates are zeroed
 *      so the settlement amounts are exact.
 */
contract OracleMarketLiquidationTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal usdcAnchor;
    MockChainlinkFeed internal wethAnchor;
    PythChainlinkOracle internal oracle;

    LendingMarket internal market;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");

    bytes32 internal constant USDC_FEED_ID = keccak256("USDC/USD");
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");

    uint256 internal constant FEE = 1 wei;
    int32 internal constant EXPO = -8;
    uint256 internal constant FEE_BUDGET = 0.5 ether;

    // Two feeds per blob, pushed once for the base and once for WETH: 2 calls * 2 updates * FEE.
    uint256 internal constant FEE_PER_LIQUIDATION_CALL = 4 * FEE;

    uint256 internal constant COLLATERAL = 10e18;
    uint256 internal constant DEBT = 15_000e6;
    int64 internal constant CRASH_PRICE = 1_700e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);

        pyth = new MockPyth(365 days, FEE);
        usdcAnchor = new MockChainlinkFeed(8, 1e8, block.timestamp);
        wethAnchor = new MockChainlinkFeed(8, 2_000e8, block.timestamp);
        oracle = _deployOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(usdc), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        market = new LendingMarket(cfg, collaterals);

        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(market), type(uint256).max);
        market.supply(address(usdc), 1_000_000e6);
        vm.stopPrank();

        // Alice borrows 15,000 USDC against 10 WETH at $2,000: capacity 10 * 1,998 * 80% = $15,984.
        weth.mint(alice, COLLATERAL);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), COLLATERAL);
        market.withdraw{value: FEE_BUDGET}(address(usdc), DEBT, _blob(2_000e8));
        vm.stopPrank();

        usdc.mint(liquidator, 1_000_000e6);
        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);
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

    /// @dev A two-feed update blob (USDC $1, WETH at `wethPrice` with a $2 band) at the current time.
    function _blob(int64 wethPrice) internal view returns (bytes[] memory update) {
        update = new bytes[](2);
        update[0] = pyth.createPriceFeedUpdateData(USDC_FEED_ID, 1e8, 0, EXPO, 1e8, 0, uint64(block.timestamp));
        update[1] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, wethPrice, 2e8, EXPO, wethPrice, 2e8, uint64(block.timestamp));
    }

    /// @dev Crash WETH to $1,700 on the anchor and return the matching signed Pyth update, one second
    ///      later so MockPyth accepts it as strictly newer. Liquidation capacity drops to
    ///      10 * 1,702 * 85% = $14,467 < $15,000 debt, so alice becomes absorbable.
    function _crash() internal returns (bytes[] memory update) {
        vm.warp(block.timestamp + 1);
        wethAnchor.setAnswer(CRASH_PRICE, block.timestamp);
        update = _blob(CRASH_PRICE);
    }

    function _absorbAlice() internal {
        bytes[] memory update = _crash();
        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(alice, update);
    }

    /*//////////////////////////////////////////////////////////////
                                ABSORB
    //////////////////////////////////////////////////////////////*/

    function test_absorbAgainstRealOracle_seizesSettlesAndRefunds() public {
        bytes[] memory update = _crash();
        uint256 ethBefore = liquidator.balance;
        int256 reservesBefore = market.getReserves();

        // Before the push the stored Pyth price ($2,000) disagrees with the moved anchor by 1,764 bps,
        // so the view refuses to price at all: only the absorb's own update can make alice eligible.
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.PriceDeviationTooHigh.selector, address(weth), 1_764, 300)
        );
        market.isLiquidatable(alice);

        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(alice, update);

        // Credit 10 * 1,700 * 93% = 15,810 USDC against 15,000 debt: 810 surplus credited to alice.
        assertEq(market.borrowBalanceOf(alice), 0, "debt wiped");
        assertEq(market.balanceOf(alice), 810e6, "surplus credited as base supply");
        assertEq(market.userCollateral(alice, address(weth)), 0, "collateral seized");
        assertEq(market.getCollateralReserves(address(weth)), COLLATERAL, "seized inventory");
        assertEq(market.getReserves(), reservesBefore - int256(15_810e6), "reserves pay the full credit");

        assertEq(ethBefore - liquidator.balance, FEE_PER_LIQUIDATION_CALL, "only the pyth fee is consumed");
        assertEq(address(market).balance, 0, "market holds no ETH");
        assertEq(address(oracle).balance, 0, "oracle holds no ETH");
    }

    function test_absorbRevertsWhenUnderfunded() public {
        bytes[] memory update = _crash();
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientFee.selector, 0, 2 * FEE));
        market.absorb{value: 0}(alice, update);
    }

    /*//////////////////////////////////////////////////////////////
                            BUY COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_buyCollateralAgainstRealOracle_sellsInventoryAndRefunds() public {
        _absorbAlice();

        vm.warp(block.timestamp + 1);
        bytes[] memory update = _blob(CRASH_PRICE);

        uint256 baseAmount = 10_000e6;
        // Discount 50% * (1 - 93%) = 3.5%, so the ask is $1,640.50 per WETH.
        uint256 expectedQuote = market.quoteCollateral(address(weth), baseAmount);
        assertEq(expectedQuote, uint256(10_000e18) * 1e4 / 16_405_000, "quote at the discounted ask");

        uint256 ethBefore = liquidator.balance;
        uint256 wethBefore = weth.balanceOf(liquidator);
        int256 reservesBefore = market.getReserves();

        vm.prank(liquidator);
        market.buyCollateral{value: FEE_BUDGET}(address(weth), expectedQuote, baseAmount, liquidator, update);

        assertEq(weth.balanceOf(liquidator) - wethBefore, expectedQuote, "collateral received at the quote");
        assertEq(market.getCollateralReserves(address(weth)), COLLATERAL - expectedQuote, "inventory drawn down");
        assertEq(market.getReserves(), reservesBefore + int256(baseAmount), "reserves rise by the base paid");

        assertEq(ethBefore - liquidator.balance, FEE_PER_LIQUIDATION_CALL, "only the pyth fee is consumed");
        assertEq(address(market).balance, 0, "market holds no ETH");
        assertEq(address(oracle).balance, 0, "oracle holds no ETH");
    }

    function test_buyCollateralRevertsWhenUnderfunded() public {
        _absorbAlice();

        bytes[] memory update = _blob(CRASH_PRICE);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientFee.selector, 0, 2 * FEE));
        market.buyCollateral{value: 0}(address(weth), 0, 10_000e6, liquidator, update);
    }
}
