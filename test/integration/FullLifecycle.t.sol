// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title FullLifecycleTest
 * @notice Phase 8 item 8.6: the whole protocol lifecycle driven end to end in one sequence on a
 *         production LendingMarket (no harness), against the real InterestRateModel and a
 *         MockPriceOracle standing in for the Pyth/Chainlink pipeline. Supply, borrow, warp with
 *         real accrual, repay, absorb, and buyCollateral run in order, and the invariants that tie
 *         them together are asserted at each hand-off, not just at the ends.
 * @dev The oracle is mocked deliberately: the point here is the market's own state machine across a
 *      full sequence, with prices as a controllable input. The real oracle pipeline is proven
 *      separately by OracleMarketBorrowTest (item 5.8) and the mainnet fork suite (item 8.7).
 */
contract FullLifecycleTest is Test {
    LendingMarket internal market;
    InterestRateModel internal irm;
    MockPriceOracle internal oracle;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant COLLATERAL = 10e18; // 10 WETH
    uint256 internal constant NO_PRICE_UPDATE = 0; // msg.value: the mock charges no fee

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Reference curve (Guide 2, Section 11): base 0, 5% APR at kink, 100%/yr jump, 80% kink, 10% RF.
        irm = new InterestRateModel(0, (0.05e18) / SECONDS_PER_YEAR, (1e18) / SECONDS_PER_YEAR, 0.8e18, 0.1e18);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(usdc), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(usdc), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        market = new LendingMarket(cfg, collaterals);

        usdc.mint(lp, 1_000_000e6);
        usdc.mint(alice, 100_000e6); // for repay
        usdc.mint(liquidator, 1_000_000e6); // for buyCollateral
        weth.mint(alice, COLLATERAL);

        vm.prank(lp);
        usdc.approve(address(market), type(uint256).max);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        weth.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);
    }

    /// @notice supply -> borrow -> warp -> repay -> absorb -> buyCollateral, asserting the tie-ins.
    /// @dev Split into per-step helpers so each closes its own scope: the sequence is deep enough to
    ///      hit "stack too deep" if inlined. State that must cross a step boundary is read back from
    ///      the market, never carried in a local.
    function test_fullLifecycle_supplyBorrowAccrueRepayAbsorbBuy() public {
        _supply();
        _borrow();
        _warpAndAccrue();
        _repay();
        _absorb();
        _buyCollateral();
    }

    /// @dev 1. SUPPLY. LP funds the base cash; alice posts 10 WETH collateral.
    function _supply() internal {
        vm.prank(lp);
        market.supply(address(usdc), 500_000e6);
        vm.prank(alice);
        market.supply(address(weth), COLLATERAL);

        assertEq(market.balanceOf(lp), 500_000e6, "LP base credited");
        assertEq(market.userCollateral(alice, address(weth)), COLLATERAL, "collateral custodied");
        assertEq(market.getUtilization(), 0, "no borrow yet");
    }

    /// @dev 2. BORROW. Capacity = 10 * 2000 * 80% = 16,000; borrow 12,000, comfortably inside.
    function _borrow() internal {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.withdraw{value: NO_PRICE_UPDATE}(address(usdc), 12_000e6, new bytes[](0));

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 12_000e6, "borrowed base received");
        assertEq(market.borrowBalanceOf(alice), 12_000e6, "debt opened");
        assertGt(market.getUtilization(), 0, "utilization rose with the borrow");
    }

    /// @dev 3. WARP. A year of accrual grows both the debt and the LP's supply balance; the borrow
    ///      index outgrows the supply index, so reserves accumulate the spread.
    function _warpAndAccrue() internal {
        uint256 debtBefore = market.borrowBalanceOf(alice);
        uint256 lpBalanceBefore = market.balanceOf(lp);
        int256 reservesBefore = market.getReserves();

        vm.warp(block.timestamp + 365 days);
        market.accrue();

        assertGt(market.borrowBalanceOf(alice), debtBefore, "debt grew with interest");
        assertGt(market.balanceOf(lp), lpBalanceBefore, "supplier earned interest");
        assertGt(market.getReserves(), reservesBefore, "reserves captured the spread");
    }

    /// @dev 4. REPAY. Alice repays part of the accrued debt by supplying base back.
    function _repay() internal {
        uint256 debtBefore = market.borrowBalanceOf(alice);
        vm.prank(alice);
        market.supply(address(usdc), 4_000e6);

        assertApproxEqAbs(market.borrowBalanceOf(alice), debtBefore - 4_000e6, 1, "debt fell by the repaid amount");
        assertGt(market.borrowBalanceOf(alice), 0, "still a live borrower");
    }

    /// @dev 5. ABSORB. WETH crashes so alice is underwater; the liquidator absorbs her permissionlessly.
    function _absorb() internal {
        oracle.setPrice(address(weth), 800e18, 0);
        assertTrue(market.isLiquidatable(alice), "position is now liquidatable");

        uint256 debtToWipe = market.borrowBalanceOf(alice);
        int256 reservesBeforeAbsorb = market.getReserves();

        vm.prank(liquidator);
        market.absorb(alice, new bytes[](0));

        assertEq(market.borrowBalanceOf(alice), 0, "debt fully wiped");
        assertEq(market.userCollateral(alice, address(weth)), 0, "collateral seized");
        // Seized inventory now lives in the gap between physical balance and the (zeroed) total.
        assertEq(market.getCollateralReserves(address(weth)), COLLATERAL, "seized WETH became protocol inventory");
        // Reserves fell by max(debt, creditBase); at $800 the credit (10*800*0.93=7,440) tops the debt.
        assertLt(market.getReserves(), reservesBeforeAbsorb, "reserves absorbed the settlement");
        assertGt(debtToWipe, 0, "there was debt to settle");
    }

    /// @dev 6. BUYCOLLATERAL. Reserves are below target, so the seized WETH is on sale at a discount.
    function _buyCollateral() internal {
        uint256 inventory = market.getCollateralReserves(address(weth));
        assertLt(market.getReserves(), int256(uint256(1_000_000e6)), "reserves below target -> for sale");

        // discount = storeFront(5000) * (FACTOR_SCALE - LF(9300)) / FACTOR_SCALE = 350 bps.
        // askPrice = price * (FACTOR_SCALE - discount) / FACTOR_SCALE = 800 * 9650/10000 = 772 (1e18).
        // The exact ask/quote rounding is pinned in QuoteRounding; here we size the buy so its quote
        // stays at or below inventory, leaving at most a sub-unit of WETH unsold.
        uint256 discount = uint256(5_000) * (10_000 - 9_300) / 10_000;
        uint256 askPrice = 800e18 * (10_000 - discount) / 10_000;
        uint256 baseToPay = inventory * askPrice / 1e18 / 1e12; // 6-dec base, floored

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        int256 reservesBeforeBuy = market.getReserves();

        vm.prank(liquidator);
        market.buyCollateral(address(weth), 0, baseToPay, liquidator, new bytes[](0));

        assertGt(weth.balanceOf(liquidator) - liquidatorWethBefore, 0, "liquidator received WETH");
        assertEq(market.getReserves() - reservesBeforeBuy, int256(baseToPay), "reserves rose by exactly the base paid");
        assertLe(market.getCollateralReserves(address(weth)), inventory, "inventory only shrank");

        // The books are internally consistent at the end: alice debt-free, inventory well-defined.
        assertEq(market.borrowBalanceOf(alice), 0, "alice ends debt-free");
    }
}
