// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title QuoteRoundingTest
 * @notice Phase 8 fuzz coverage for the storefront quote math: every division in quoteCollateral
 *         rounds toward the protocol (Guide 2, Section 9). The discount floors (a smaller discount),
 *         the ask ceils (a higher ask), and the quote floors (less collateral out). Round-trip coverage
 *         in AbsorbLiquidation can survive a flipped rounding direction; these tests pin each leg
 *         against a value computed here, so any single flipped direction fails the suite.
 * @dev Factors are fuzzed field by field (not the MarketBuilder defaults) so the discount and
 *      askPrice divisions land on non-exact quotients where the rounding direction is observable.
 */
contract QuoteRoundingTest is Test {
    uint256 internal constant FACTOR_SCALE = 10_000;
    uint256 internal constant BASE_SCALE = 1e6; // USDC 6-dec base

    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();
    }

    /// @dev Builds a market whose single WETH collateral carries the fuzzed storefront/LF factors.
    function _market(uint16 storeFront, uint16 liquidationFactor) internal returns (LendingMarketHarness market) {
        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = ILendingMarket.CollateralConfig({
            asset: address(weth),
            borrowCollateralFactor: 8000,
            liquidateCollateralFactor: 8500,
            liquidationFactor: liquidationFactor,
            storeFrontPriceFactor: storeFront,
            supplyCap: 1_000e18,
            decimals: 18
        });
        market = new LendingMarketHarness(cfg, collaterals);
    }

    /// @dev The ask the contract must produce: the discount floored (a smaller discount), then the ask
    ///      ceiled (a higher ask), in plain integer arithmetic.
    function _expectedAskPrice(uint256 price, uint16 storeFront, uint16 liquidationFactor)
        internal
        pure
        returns (uint256)
    {
        uint256 discount = (uint256(storeFront) * (FACTOR_SCALE - liquidationFactor)) / FACTOR_SCALE;
        return (price * (FACTOR_SCALE - discount) + FACTOR_SCALE - 1) / FACTOR_SCALE;
    }

    /// @dev The quote for a 1e18 base price and an 18-decimal collateral, floored.
    function _expectedQuote(uint256 baseAmount, uint256 askPrice) internal pure returns (uint256) {
        return (baseAmount * 1e18 * 1e18) / (BASE_SCALE * askPrice);
    }

    /// @notice quoteCollateral rounds each leg toward the protocol: the discount floors, the ask ceils,
    ///         and the quote floors. It must equal the value computed here leg by leg.
    /// @dev Half the runs price WETH from 1 wei to 1,000 USD. There one wei of ask moves the quote by
    ///      about baseAmount * 1e30 / ask^2, so the ceiled and floored asks usually give different
    ///      quotes, and at the lowest prices the floored ask is 0. The other half cover 1 to 1,000,000
    ///      USD. Bounds keep every plain product in uint256: baseAmount * 1e18 * 1e18 <= 1e48,
    ///      price * FACTOR_SCALE <= 1e28 and BASE_SCALE * askPrice <= 1e30.
    function testFuzz_quoteCollateral_matchesDirectedRounding(
        uint256 baseAmount,
        uint256 priceRaw,
        uint16 storeFront,
        uint16 liquidationFactor,
        bool lowPrice
    ) public {
        // Valid config domain: 0 < storeFront <= FACTOR_SCALE, and INV-13 forces
        // liquidationFactor >= ceil(liquidateCF * (1 + maxConfBps)) = ceil(8500 * 1.02) = 8670.
        // Cap below FACTOR_SCALE so the discount is non-zero and its floor stays observable.
        storeFront = uint16(bound(storeFront, 1, FACTOR_SCALE));
        liquidationFactor = uint16(bound(liquidationFactor, 8670, FACTOR_SCALE - 1));

        uint256 price = lowPrice ? bound(priceRaw, 1, 1_000e18) : bound(priceRaw, 1e18, 1_000_000e18);
        baseAmount = bound(baseAmount, 0, 1_000_000e6);

        LendingMarketHarness market = _market(storeFront, liquidationFactor);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), price, 0);

        uint256 askPrice = _expectedAskPrice(price, storeFront, liquidationFactor);
        assertEq(
            market.quoteCollateral(address(weth), baseAmount),
            _expectedQuote(baseAmount, askPrice),
            "quote did not follow the directed rounding"
        );
    }

    /// @notice A 1 USD + 1 wei collateral at the reference factors: the discount is 350 bps and the ask
    ///         is 965e15 + 0.965 wei, ceiled to 965e15 + 1. For 1,000 USDC that quotes
    ///         1,036.269430051813470428e18 WETH; the floored ask would give 1,074 wei more.
    function test_quoteCollateral_roundsAskUp() public {
        LendingMarketHarness market = _market(5000, 9300);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 1e18 + 1, 0);

        assertEq(market.quoteCollateral(address(weth), 1_000e6), 1_036_269_430_051_813_470_428, "ask did not round up");
    }

    /// @notice At a price of 1 wei the floored ask would be 0 and the quote would divide by zero; the
    ///         ceiled ask is 1, so 1 USDC quotes 1e36 wei of collateral.
    function test_quoteCollateral_askIsNeverZero() public {
        LendingMarketHarness market = _market(5000, 9300);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 1, 0);

        assertEq(market.quoteCollateral(address(weth), 1e6), 1e36, "ask rounded to zero");
    }

    /// @notice A larger base payment never quotes strictly less collateral (monotone, floored).
    function testFuzz_quoteCollateral_isMonotone(uint256 lowBase, uint256 highBase, uint256 priceRaw) public {
        uint256 price = bound(priceRaw, 1e18, 1_000_000e18);
        lowBase = bound(lowBase, 0, 1_000_000e6);
        highBase = bound(highBase, lowBase, 1_000_000e6);

        LendingMarketHarness market = _market(5000, 9300);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), price, 0);

        assertLe(
            market.quoteCollateral(address(weth), lowBase),
            market.quoteCollateral(address(weth), highBase),
            "quote not monotone in base paid"
        );
    }

    /// @notice The ask never exceeds the raw price: the discount can only lower what the buyer pays,
    ///         never raise it, for any valid factor pair.
    function testFuzz_askPrice_neverAboveSpot(uint256 priceRaw, uint16 storeFront, uint16 liquidationFactor) public {
        storeFront = uint16(bound(storeFront, 1, FACTOR_SCALE));
        liquidationFactor = uint16(bound(liquidationFactor, 8670, FACTOR_SCALE));
        uint256 price = bound(priceRaw, 1e18, 1_000_000e18);

        // askPrice = price * (1 - discount) <= price, and quote scales inversely with askPrice, so a
        // discounted ask yields at least as much collateral per base as the spot ask would.
        LendingMarketHarness spot = _market(1, uint16(FACTOR_SCALE)); // discount == 0 -> ask == price
        LendingMarketHarness discounted = _market(storeFront, liquidationFactor);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), price, 0);

        uint256 quoteSpot = spot.quoteCollateral(address(weth), 1_000e6);
        uint256 quoteDiscounted = discounted.quoteCollateral(address(weth), 1_000e6);
        assertGe(quoteDiscounted, quoteSpot, "discount reduced collateral received");
    }
}
