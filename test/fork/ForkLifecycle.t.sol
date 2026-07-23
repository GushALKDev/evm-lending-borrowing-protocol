// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title ForkLifecycle
 * @notice Phase 8 item 8.7: the full lifecycle against the real external dependencies on an Ethereum
 *         mainnet fork. A market is deployed fresh on the fork over the real USDC (base) and real WETH
 *         (collateral), priced by the real PythChainlinkOracle wired to the real Pyth pull oracle and
 *         the real Chainlink ETH/USD and USDC/USD aggregators. The lifecycle runs supply, borrow,
 *         accrual, and repay, reading real on-chain prices throughout.
 * @dev Prices are pushed by replaying a cached Hermes VAA (test/fork/fixtures) through the real Pyth
 *      contract: caching keeps the test deterministic (no live Hermes fetch, ffi stays off) while still
 *      exercising the real updatePriceFeeds fee/refund path and the real getPriceUnsafe read. The VAA
 *      carries USDC and WETH at one shared publishTime, so a single warp leaves both fresh under the
 *      reference 60s staleness window. Run only when FORK_RPC_URL is set; skipped otherwise.
 *
 *      absorb and buyCollateral are deliberately out of scope here. With real, fixed fork prices the
 *      only lever to drive an account underwater is interest accrual over time, but warping forward
 *      makes the cached VAA stale (publishTime is fixed and cannot be refetched for a future block),
 *      and the constructor forbids borrowCF >= liquidateCF, so an account cannot be borrowed straight
 *      into liquidation either. Those two paths are covered exhaustively at unit, fuzz, and invariant
 *      level against controlled prices; the fork test targets the paths where a *real* price is
 *      load-bearing (validation pipeline, borrow capacity, accrual).
 */
contract ForkLifecycleTest is Test {
    // --- Ethereum mainnet addresses ---
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    address internal constant CL_USDC = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC / USD
    address internal constant CL_WETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH / USD

    // --- Pyth feed IDs ---
    bytes32 internal constant USDC_FEED_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant WETH_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // --- Fixture pin (see test/fork/fixtures/README.md) ---
    uint256 internal constant FORK_BLOCK = 25_595_265;
    uint256 internal constant VAA_PUBLISH_TIME = 1_784_807_706;

    PythChainlinkOracle internal oracle;
    InterestRateModel internal irm;
    LendingMarket internal market;
    bytes[] internal priceUpdate;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no RPC: every test no-ops (see _skip)
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        // Warp to the VAA publish time so the pushed prices are fresh under MAX_STALENESS (60s).
        vm.warp(VAA_PUBLISH_TIME);

        priceUpdate = new bytes[](1);
        priceUpdate[0] = vm.parseBytes(vm.readFile("test/fork/fixtures/pyth_usdc_weth.hex"));

        oracle = _deployOracle();
        irm = new InterestRateModel(0, (0.05e18) / uint256(365 days), (1e18) / uint256(365 days), 0.8e18, 0.1e18);

        LendingMarket.MarketConfig memory cfg = LendingMarket.MarketConfig({
            baseToken: USDC,
            interestRateModel: address(irm),
            oracle: address(oracle),
            owner: owner,
            guardian: guardian,
            minBorrow: 100e6,
            targetReserves: 100_000e6
        });
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = ILendingMarket.CollateralConfig({
            asset: WETH,
            borrowCollateralFactor: 8000,
            liquidateCollateralFactor: 8500,
            liquidationFactor: 9300,
            storeFrontPriceFactor: 5000,
            supplyCap: 1_000e18,
            decimals: 18
        });
        market = new LendingMarket(cfg, collaterals);

        // Fund actors with real tokens via deal (no real value moves; this is a local fork).
        deal(USDC, lp, 2_000_000e6);
        deal(WETH, alice, 20e18);
        vm.deal(alice, 1 ether);
    }

    function _deployOracle() internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](2);
        // Heartbeats sized to cover the real anchors' age at the pinned fork block: on a fork the
        // Chainlink round does not refresh, so the window must span the block-to-updatedAt gap.
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: USDC_FEED_ID, chainlinkFeed: CL_USDC, heartbeat: 1 days, set: false
        });
        configs[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: CL_WETH, heartbeat: 1 days, set: false
        });

        // Reference thresholds: 60s staleness, 200 bps confidence, 300 bps Pyth-vs-Chainlink deviation.
        return new PythChainlinkOracle(PYTH, 60, 200, 300, assets, configs);
    }

    /// @dev Every test opens with this; when no RPC is configured the suite is a green no-op.
    function _skip() internal view returns (bool) {
        return !forked;
    }

    /*//////////////////////////////////////////////////////////////
                        THE REAL-PRICE READ WORKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sanity: the real oracle prices both assets through the full validation pipeline (real Pyth
    ///      read, real Chainlink anchor, expo/decimal normalization, confidence and deviation checks).
    function test_fork_realOraclePricesBothAssets() public {
        if (_skip()) return;

        _pushPrices();
        (uint256 usdcPrice,) = oracle.getPrice(USDC);
        (uint256 wethPrice,) = oracle.getPrice(WETH);

        // USDC ~ $1, WETH ~ $1,900s, both at 1e18 scale.
        assertApproxEqRel(usdcPrice, 1e18, 0.02e18, "USDC not ~$1");
        assertGt(wethPrice, 1_000e18, "WETH price implausibly low");
        assertLt(wethPrice, 10_000e18, "WETH price implausibly high");
    }

    /*//////////////////////////////////////////////////////////////
                            THE FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @dev supply (base + collateral) -> borrow -> accrue -> repay against real prices.
    function test_fork_supplyBorrowAccrueRepay() public {
        if (_skip()) return;

        // LP supplies base cash.
        vm.startPrank(lp);
        IERC20(USDC).approve(address(market), type(uint256).max);
        market.supply(USDC, 1_000_000e6);
        vm.stopPrank();

        // Alice posts 10 WETH and borrows 5,000 USDC (well within capacity at ~$1,900/WETH * 80%).
        vm.startPrank(alice);
        IERC20(WETH).approve(address(market), type(uint256).max);
        market.supply(WETH, 10e18);
        vm.stopPrank();

        _pushPrices();
        vm.prank(alice);
        market.withdraw{value: 0.1 ether}(USDC, 5_000e6, priceUpdate);

        assertEq(market.borrowBalanceOf(alice), 5_000e6, "debt recorded");
        assertEq(address(market).balance, 0, "market holds no ETH after refund");

        // Accrue interest over 30 days: debt must grow.
        vm.warp(block.timestamp + 30 days);
        market.accrue();
        assertGt(market.borrowBalanceOf(alice), 5_000e6, "interest did not accrue");

        // Repay in full: fund alice the accrued amount, then withdraw-side repay via supply(base).
        uint256 owed = market.borrowBalanceOf(alice);
        deal(USDC, alice, owed);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(market), type(uint256).max);
        market.supply(USDC, owed);
        vm.stopPrank();
        assertEq(market.borrowBalanceOf(alice), 0, "debt not cleared by repay");
    }

    /// @dev The market forwards its whole ETH balance to the oracle per asset and the oracle refunds
    ///      the surplus; this helper pushes the cached VAA directly to the oracle for the view reads the
    ///      tests assert on, funding the test contract with the exact Pyth fee first.
    function _pushPrices() internal {
        uint256 fee = IPyth(PYTH).getUpdateFee(priceUpdate);
        vm.deal(address(this), fee * 2);
        oracle.updateAndGetPrice{value: fee}(USDC, priceUpdate);
        oracle.updateAndGetPrice{value: fee}(WETH, priceUpdate);
    }

    receive() external payable {}
}
