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
 * @title OracleFailureModesTest
 * @notice What a failed price check does inside the market: borrow, absorb, and buyCollateral revert
 *         on StalePrice, StaleAnchor, and ConfidenceTooWide through the real PythChainlinkOracle, a
 *         broken feed for one collateral blocks whole positions that hold it, and the exit paths
 *         (supplier withdrawal, repay, debt-free collateral withdrawal) stay open through an outage.
 * @dev Oracle params are the reference 60 s staleness, 200 bps confidence, 300 bps deviation, with a
 *      3,600 s heartbeat on the collateral anchors and 86,400 s on USDC. Rates are zeroed so every
 *      position is stable across warps. alice holds WETH only; carol holds WETH and WBTC, so WBTC is
 *      the "collateral X" whose broken feed spills over onto the rest of carol's position.
 */
contract OracleFailureModesTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal usdcAnchor;
    MockChainlinkFeed internal wethAnchor;
    MockChainlinkFeed internal wbtcAnchor;
    PythChainlinkOracle internal oracle;

    LendingMarket internal market;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockInterestRateModel internal irm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");
    address internal liquidator = makeAddr("liquidator");

    bytes32 internal constant USDC_FEED_ID = keccak256("USDC/USD");
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");
    bytes32 internal constant WBTC_FEED_ID = keccak256("WBTC/USD");

    uint256 internal constant FEE = 1 wei;
    int32 internal constant EXPO = -8;
    uint256 internal constant FEE_BUDGET = 0.5 ether;

    uint256 internal constant MAX_STALENESS = 60;
    uint256 internal constant MAX_CONFIDENCE_BPS = 200;
    uint32 internal constant COLLATERAL_HEARTBEAT = 3_600;

    int64 internal constant WETH_PRICE = 2_000e8;
    int64 internal constant WBTC_PRICE = 50_000e8;
    int64 internal constant CRASH_PRICE = 1_700e8;

    /// @dev Publish time of the setUp prices, the reference point every staleness revert reports.
    uint256 internal t0;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        irm = new MockInterestRateModel(0, 0, 0.1e18);

        t0 = block.timestamp;
        pyth = new MockPyth(365 days, FEE);
        usdcAnchor = new MockChainlinkFeed(8, 1e8, t0);
        wethAnchor = new MockChainlinkFeed(8, WETH_PRICE, t0);
        wbtcAnchor = new MockChainlinkFeed(8, WBTC_PRICE, t0);
        oracle = _deployOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(usdc), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](2);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        collaterals[1] = MarketBuilder.collateral(address(wbtc), 8, 100e8);
        market = new LendingMarket(cfg, collaterals);

        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(market), type(uint256).max);
        market.supply(address(usdc), 1_000_000e6);
        vm.stopPrank();

        bytes[] memory update = _update(WETH_PRICE, 2e8);

        // alice: 10 WETH, 15,000 USDC debt against 10 * 1,998 * 80% = 15,984 of capacity.
        _fund(alice);
        vm.startPrank(alice);
        market.supply(address(weth), 10e18);
        market.withdraw{value: FEE_BUDGET}(address(usdc), 15_000e6, update);
        vm.stopPrank();

        // carol: 10 WETH and 1 WBTC, 20,000 USDC debt against 15,984 + 49,950 * 80% = 55,944.
        _fund(carol);
        vm.startPrank(carol);
        market.supply(address(weth), 10e18);
        market.supply(address(wbtc), 1e8);
        market.withdraw{value: FEE_BUDGET}(address(usdc), 20_000e6, update);
        vm.stopPrank();

        usdc.mint(liquidator, 1_000_000e6);
        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);
    }

    function _deployOracle() internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](3);
        assets[0] = address(usdc);
        assets[1] = address(weth);
        assets[2] = address(wbtc);

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](3);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: USDC_FEED_ID, chainlinkFeed: address(usdcAnchor), heartbeat: 86_400, set: false
        });
        configs[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(wethAnchor), heartbeat: COLLATERAL_HEARTBEAT, set: false
        });
        configs[2] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WBTC_FEED_ID, chainlinkFeed: address(wbtcAnchor), heartbeat: COLLATERAL_HEARTBEAT, set: false
        });
        return new PythChainlinkOracle(address(pyth), MAX_STALENESS, MAX_CONFIDENCE_BPS, 300, assets, configs);
    }

    function _fund(address account) internal {
        weth.mint(account, 10e18);
        wbtc.mint(account, 1e8);
        usdc.mint(account, 100_000e6);
        vm.deal(account, 1 ether);
        vm.startPrank(account);
        weth.approve(address(market), type(uint256).max);
        wbtc.approve(address(market), type(uint256).max);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A fresh three-feed update at the current time: USDC at $1, WETH at `wethPrice` with a
    ///      `wethConf` band, WBTC at $50,000 with a $50 band.
    function _update(int64 wethPrice, uint64 wethConf) internal view returns (bytes[] memory update) {
        uint64 nowTime = uint64(block.timestamp);
        update = new bytes[](3);
        update[0] = pyth.createPriceFeedUpdateData(USDC_FEED_ID, 1e8, 0, EXPO, 1e8, 0, nowTime);
        update[1] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, wethPrice, wethConf, EXPO, wethPrice, wethConf, nowTime);
        update[2] = pyth.createPriceFeedUpdateData(WBTC_FEED_ID, WBTC_PRICE, 50e8, EXPO, WBTC_PRICE, 50e8, nowTime);
    }

    /// @dev A fresh update for the base alone, so the base check passes and the collateral one fails.
    function _baseOnlyUpdate() internal view returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(USDC_FEED_ID, 1e8, 0, EXPO, 1e8, 0, uint64(block.timestamp));
    }

    /// @dev Stores a WETH crash to $1,700 on both sources, one second later. alice's liquidation
    ///      capacity drops to 10 * 1,702 * 85% = 14,467 < 15,000, so alice becomes absorbable.
    function _storeCrash() internal {
        vm.warp(block.timestamp + 1);
        wethAnchor.setAnswer(CRASH_PRICE, block.timestamp);
        bytes[] memory update = _update(CRASH_PRICE, 2e8);
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(update)}(update);
    }

    function _absorbAlice() internal {
        _storeCrash();
        bytes[] memory update = _update(CRASH_PRICE, 2e8);
        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(alice, update);
    }

    function _staleAnchorError(address asset, uint256 updatedAt) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PythChainlinkOracle.StaleAnchor.selector, asset, updatedAt, COLLATERAL_HEARTBEAT);
    }

    /*//////////////////////////////////////////////////////////////
                        STALE PYTH PRICE (StalePrice)
    //////////////////////////////////////////////////////////////*/

    function test_stalePrice_blocksBorrow() public {
        vm.warp(t0 + MAX_STALENESS + 1);

        bytes[] memory update = _baseOnlyUpdate();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, address(weth), t0, MAX_STALENESS)
        );
        market.withdraw{value: FEE_BUDGET}(address(usdc), 100e6, update);
    }

    /// @dev A stale Pyth price is the one failure the caller can cure: the same absorb with a fresh
    ///      update attached succeeds.
    function test_stalePrice_blocksAbsorbUntilAFreshUpdate() public {
        _storeCrash();
        uint256 crashTime = block.timestamp;
        vm.warp(crashTime + MAX_STALENESS + 1);

        bytes[] memory baseOnly = _baseOnlyUpdate();
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, address(weth), crashTime, MAX_STALENESS)
        );
        market.absorb{value: FEE_BUDGET}(alice, baseOnly);

        bytes[] memory fresh = _update(CRASH_PRICE, 2e8);
        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(alice, fresh);
        assertEq(market.borrowBalanceOf(alice), 0, "absorbed once the price is fresh");
    }

    function test_stalePrice_blocksBuyCollateral() public {
        _absorbAlice();
        uint256 absorbTime = block.timestamp;
        vm.warp(absorbTime + MAX_STALENESS + 1);

        bytes[] memory update = _baseOnlyUpdate();
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, address(weth), absorbTime, MAX_STALENESS)
        );
        market.buyCollateral{value: FEE_BUDGET}(address(weth), 0, 1_000e6, liquidator, update);
    }

    /*//////////////////////////////////////////////////////////////
                     STALE CHAINLINK ANCHOR (StaleAnchor)
    //////////////////////////////////////////////////////////////*/

    function test_staleAnchor_blocksBorrow() public {
        vm.warp(t0 + COLLATERAL_HEARTBEAT + 1);

        bytes[] memory update = _update(WETH_PRICE, 2e8);
        vm.prank(alice);
        vm.expectRevert(_staleAnchorError(address(weth), t0));
        market.withdraw{value: FEE_BUDGET}(address(usdc), 100e6, update);
    }

    /// @dev Unlike a stale Pyth price, a stale anchor is not cured by the caller: the absorb carries a
    ///      fresh Pyth update and still reverts. It resumes only once Chainlink itself updates.
    function test_staleAnchor_blocksAbsorbDespiteAFreshUpdate() public {
        vm.warp(t0 + COLLATERAL_HEARTBEAT + 1);
        wethAnchor.setAnswer(CRASH_PRICE, t0);

        bytes[] memory update = _update(CRASH_PRICE, 2e8);
        vm.prank(liquidator);
        vm.expectRevert(_staleAnchorError(address(weth), t0));
        market.absorb{value: FEE_BUDGET}(alice, update);

        wethAnchor.setAnswer(CRASH_PRICE, block.timestamp);
        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(alice, update);
        assertEq(market.borrowBalanceOf(alice), 0, "absorbed once the anchor updates");
    }

    function test_staleAnchor_blocksBuyCollateral() public {
        _absorbAlice();
        uint256 anchorTime = block.timestamp;
        vm.warp(anchorTime + COLLATERAL_HEARTBEAT + 1);

        bytes[] memory update = _update(CRASH_PRICE, 2e8);
        vm.prank(liquidator);
        vm.expectRevert(_staleAnchorError(address(weth), anchorTime));
        market.buyCollateral{value: FEE_BUDGET}(address(weth), 0, 1_000e6, liquidator, update);
    }

    /*//////////////////////////////////////////////////////////////
                   WIDE CONFIDENCE BAND (ConfidenceTooWide)
    //////////////////////////////////////////////////////////////*/

    /// @dev A $50 band on $2,000 is 250 bps, past the 200 bps ceiling.
    function test_confidenceTooWide_blocksBorrow() public {
        vm.warp(t0 + 1);

        bytes[] memory update = _update(WETH_PRICE, 50e8);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythChainlinkOracle.ConfidenceTooWide.selector, address(weth), 250, MAX_CONFIDENCE_BPS
            )
        );
        market.withdraw{value: FEE_BUDGET}(address(usdc), 100e6, update);
    }

    /// @dev A $40 band on $1,700 is 235 bps (floored).
    function test_confidenceTooWide_blocksAbsorb() public {
        vm.warp(t0 + 1);
        wethAnchor.setAnswer(CRASH_PRICE, block.timestamp);

        bytes[] memory update = _update(CRASH_PRICE, 40e8);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythChainlinkOracle.ConfidenceTooWide.selector, address(weth), 235, MAX_CONFIDENCE_BPS
            )
        );
        market.absorb{value: FEE_BUDGET}(alice, update);
    }

    function test_confidenceTooWide_blocksBuyCollateral() public {
        _absorbAlice();
        vm.warp(block.timestamp + 1);

        bytes[] memory update = _update(CRASH_PRICE, 40e8);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythChainlinkOracle.ConfidenceTooWide.selector, address(weth), 235, MAX_CONFIDENCE_BPS
            )
        );
        market.buyCollateral{value: FEE_BUDGET}(address(weth), 0, 1_000e6, liquidator, update);
    }

    /*//////////////////////////////////////////////////////////////
               BROKEN FEED FOR ONE COLLATERAL (cross-collateral)
    //////////////////////////////////////////////////////////////*/

    /// @dev Breaks only the WBTC anchor: every other feed is fresh for the rest of the test.
    function _breakWbtcFeed() internal {
        vm.warp(t0 + COLLATERAL_HEARTBEAT + 1);
        usdcAnchor.setAnswer(1e8, block.timestamp);
        wethAnchor.setAnswer(WETH_PRICE, block.timestamp);
    }

    /// @dev carol's WETH alone would support more debt, but every health check prices all of her
    ///      collateral, so the broken WBTC feed blocks the borrow.
    function test_brokenCollateralFeed_blocksBorrowForAnAccountHoldingIt() public {
        _breakWbtcFeed();

        bytes[] memory update = _update(WETH_PRICE, 2e8);
        vm.prank(carol);
        vm.expectRevert(_staleAnchorError(address(wbtc), t0));
        market.withdraw{value: FEE_BUDGET}(address(usdc), 100e6, update);
    }

    /// @dev The asset withdrawn is WETH, whose feed is healthy; the revert names WBTC.
    function test_brokenCollateralFeed_blocksWithdrawingOtherCollateral() public {
        _breakWbtcFeed();

        bytes[] memory update = _update(WETH_PRICE, 2e8);
        vm.prank(carol);
        vm.expectRevert(_staleAnchorError(address(wbtc), t0));
        market.withdraw{value: FEE_BUDGET}(address(weth), 1e18, update);
    }

    /// @dev carol first borrows up to 55,000 (capacity 55,944). A WETH crash to $1,000 then leaves her
    ///      10 * 1,002 * 85% + 50,050 * 85% = 51,059 USD of liquidation capacity, so carol is absorbable
    ///      on the WETH move alone. The absorb still reverts on WBTC: it prices and seizes the whole
    ///      account, with no partial mode, and only succeeds once the WBTC anchor updates.
    function test_brokenCollateralFeed_blocksAbsorbOfTheWholeAccount() public {
        vm.prank(carol);
        market.withdraw{value: FEE_BUDGET}(address(usdc), 35_000e6, new bytes[](0));

        _breakWbtcFeed();
        wethAnchor.setAnswer(1_000e8, block.timestamp);

        bytes[] memory update = _update(1_000e8, 2e8);
        vm.prank(liquidator);
        vm.expectRevert(_staleAnchorError(address(wbtc), t0));
        market.absorb{value: FEE_BUDGET}(carol, update);

        wbtcAnchor.setAnswer(WBTC_PRICE, block.timestamp);
        vm.prank(liquidator);
        market.absorb{value: FEE_BUDGET}(carol, update);
        assertEq(market.borrowBalanceOf(carol), 0, "absorbed once the WBTC anchor updates");
        assertEq(market.userCollateral(carol, address(wbtc)), 0, "WBTC seized with the rest");
    }

    /// @dev The same outage leaves an account that does not hold WBTC untouched.
    function test_brokenCollateralFeed_leavesAccountsWithoutItUnaffected() public {
        _breakWbtcFeed();

        bytes[] memory update = _update(WETH_PRICE, 2e8);
        vm.prank(alice);
        market.withdraw{value: FEE_BUDGET}(address(usdc), 500e6, update);
        assertEq(market.borrowBalanceOf(alice), 15_500e6, "alice borrows while WBTC is broken");
    }

    /// @dev The exit from a broken collateral: repay (no oracle), then withdraw the whole broken asset.
    ///      Zeroing a balance clears its assetsIn bit before the health check, so WBTC is no longer
    ///      priced and the remaining WETH (15,984 of capacity) covers the 10,000 left.
    function test_brokenCollateralFeed_debtorCanRepayThenExitTheBrokenAsset() public {
        _breakWbtcFeed();

        bytes[] memory update = _update(WETH_PRICE, 2e8);
        vm.prank(carol);
        vm.expectRevert(_staleAnchorError(address(wbtc), t0));
        market.withdraw{value: FEE_BUDGET}(address(wbtc), 0.5e8, update);

        vm.startPrank(carol);
        market.supply(address(usdc), 10_000e6);
        market.withdraw{value: FEE_BUDGET}(address(wbtc), 1e8, update);
        vm.stopPrank();

        assertEq(market.userCollateral(carol, address(wbtc)), 0, "WBTC fully withdrawn");
        assertEq(market.borrowBalanceOf(carol), 10_000e6, "debt still backed by WETH");
    }

    /*//////////////////////////////////////////////////////////////
                         EXIT PATHS DURING AN OUTAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Every anchor stale and no Pyth update at all: a supplier still withdraws, a borrower still
    ///      repays in full, and a debt-free account still withdraws its collateral. None of these
    ///      reads a price.
    function test_outage_exitPathsStayOpen() public {
        vm.warp(t0 + 86_400 + 1);

        vm.prank(lp);
        market.withdraw(address(usdc), 100_000e6, new bytes[](0));
        assertEq(market.balanceOf(lp), 900_000e6, "supplier withdrew");

        vm.startPrank(alice);
        market.supply(address(usdc), type(uint256).max);
        market.withdraw(address(weth), 10e18, new bytes[](0));
        vm.stopPrank();
        assertEq(market.borrowBalanceOf(alice), 0, "borrower repaid");
        assertEq(market.userCollateral(alice, address(weth)), 0, "and withdrew the collateral");
    }
}
