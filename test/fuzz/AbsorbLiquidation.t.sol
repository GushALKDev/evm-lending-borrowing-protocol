// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title AbsorbLiquidationFuzzTest
 * @notice Phase 6 fuzz: the absorb settlement and the discount round trip across a range of prices.
 * @dev Reference collateral: 10 WETH, liquidateCF 85%, LF 93%, storeFront 50%, base 1 USD.
 */
contract AbsorbLiquidationFuzzTest is Test {
    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant COLLATERAL = 10e18;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        cfg.targetReserves = 100_000_000e6;

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);

        base.mint(bob, 100_000_000e6);
        base.mint(carol, 100_000_000e6);
        weth.mint(alice, COLLATERAL);

        vm.prank(alice);
        weth.approve(address(market), type(uint256).max);
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.prank(carol);
        base.approve(address(market), type(uint256).max);

        vm.prank(bob);
        market.supply(address(base), 50_000_000e6);

        // Alice opens the max borrow at the initial 2,000 price (capacity 16,000).
        vm.startPrank(alice);
        market.supply(address(weth), COLLATERAL);
        market.withdraw(address(base), 16_000e6, new bytes[](0));
        vm.stopPrank();
    }

    /// @notice For any liquidatable price, absorb wipes the debt, seizes all collateral, and never
    ///         credits a surplus while leaving debt: the account ends at zero or supplied, never owing.
    function testFuzz_absorb_settlesConsistently(uint256 priceRaw) public {
        // Liquidatable requires debt (16,000) > 10 * price * 0.85, i.e. price < 1,882.35.
        uint256 price = bound(priceRaw, 100e18, 1_882e18);
        oracle.setPrice(address(weth), price, 0);
        vm.assume(market.isLiquidatable(alice));

        uint256 debt = market.borrowBalanceOf(alice);
        int256 reservesBefore = market.getReserves();

        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        // Debt always fully wiped, collateral always fully seized.
        assertEq(market.borrowBalanceOf(alice), 0, "debt wiped");
        assertEq(market.userCollateral(alice, address(weth)), 0, "collateral seized");
        assertEq(market.getAssetsIn(alice), 0, "bit cleared");

        // Reserves fall by max(debt, creditBase). credit = 10 * price * 0.93 in base.
        uint256 creditBase = (COLLATERAL * price / 1e18) * 9300 / 10000 / 1e12; // to 6-dec base
        uint256 expectedFall = creditBase > debt ? creditBase : debt;
        // Allow 1 base unit of rounding slack from the floored conversions.
        assertApproxEqAbs(uint256(reservesBefore - market.getReserves()), expectedFall, 1, "reserves fall");

        // The account is never left owing after an absorb.
        assertGe(int256(market.balanceOf(alice)), int256(0), "never left owing");
    }

    /// @notice A buy raises reserves by exactly the base paid in (no principal changes), and selling
    ///         the whole seized inventory at the same price always returns at least the credit the
    ///         absorb spent on the account. In the surplus/exact case that makes the round trip
    ///         reserve-non-negative; in the shortfall case the gap to the full debt is exactly the
    ///         already-recognized bad debt (Guide 2, Section 9). The discount is bounded by the
    ///         liquidation penalty, so proceeds >= credit holds across the whole price range.
    function testFuzz_absorbThenSell_proceedsCoverCredit(uint256 priceRaw) public {
        uint256 price = bound(priceRaw, 500e18, 1_882e18);
        oracle.setPrice(address(weth), price, 0);
        vm.assume(market.isLiquidatable(alice));

        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
        int256 reservesAfterAbsorb = market.getReserves();

        // creditValue = 10 * price * LF, credited to the account in base at absorb time.
        uint256 creditBase = (COLLATERAL * price / 1e18) * 9300 / 10000 / 1e12;

        // Buy the largest whole-base amount whose quote stays within the inventory (floor the
        // inverse), leaving at most a sub-unit of collateral unsold.
        uint256 discount = uint256(5000) * (10000 - 9300) / 10000; // storeFront * (1 - LF), bps
        uint256 askPrice = price * (10000 - discount) / 10000; // 1e18 scale
        uint128 inventory = market.totalsCollateral(address(weth));
        uint256 baseForAll = FixedPointMathLib.fullMulDiv(inventory, askPrice, 1e30); // 6-dec base, floor

        vm.prank(carol);
        market.buyCollateral(address(weth), 0, baseForAll, carol, new bytes[](0));

        // A buy moves only cash, so reserves rise by exactly the base paid in.
        assertEq(market.getReserves() - reservesAfterAbsorb, int256(baseForAll), "reserves rise by base paid");
        // Proceeds plus the tiny unsold remainder always cover the credit the absorb spent.
        uint256 residualValueBase = uint256(market.totalsCollateral(address(weth))) * price / 1e18 / 1e12;
        assertGe(baseForAll + residualValueBase + 1, creditBase, "proceeds cover the absorb credit");
    }
}
