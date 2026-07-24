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
 * @title QuoteRoundingTest
 * @notice Phase 8 fuzz coverage for the storefront quote math: every division in quoteCollateral
 *         floors, so the buyer never receives more collateral than the ask supports (Guide 2,
 *         Section 9). Round-trip coverage in AbsorbLiquidation can survive a flipped rounding
 *         direction; these tests pin each site against its exact truncated quotient instead, so any
 *         single flipped floor -> ceil fails the suite.
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

    /// @dev Recomputes the exact floored discount/askPrice the contract must produce.
    function _expectedAskPrice(uint256 price, uint16 storeFront, uint16 liquidationFactor)
        internal
        pure
        returns (uint256)
    {
        uint256 discount = (uint256(storeFront) * (FACTOR_SCALE - liquidationFactor)) / FACTOR_SCALE;
        return (price * (FACTOR_SCALE - discount)) / FACTOR_SCALE;
    }

    /// @notice quoteCollateral floors on every leg: it must equal the exact truncated quotient.
    function testFuzz_quoteCollateral_floorsExactly(
        uint256 baseAmount,
        uint256 priceRaw,
        uint16 storeFront,
        uint16 liquidationFactor
    ) public {
        // Valid config domain: 0 < storeFront <= FACTOR_SCALE, and INV-13 forces
        // liquidationFactor >= ceil(liquidateCF * (1 + maxConfBps)) = ceil(8500 * 1.02) = 8670.
        // Cap below FACTOR_SCALE so the discount is non-zero and its floor stays observable.
        storeFront = uint16(bound(storeFront, 1, FACTOR_SCALE));
        liquidationFactor = uint16(bound(liquidationFactor, 8670, FACTOR_SCALE - 1));

        uint256 price = bound(priceRaw, 1e18, 1_000_000e18);
        baseAmount = bound(baseAmount, 0, 1_000_000e6);

        LendingMarketHarness market = _market(storeFront, liquidationFactor);
        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), price, 0);

        uint256 askPrice = _expectedAskPrice(price, storeFront, liquidationFactor);
        // basePrice = 1e18, collateralScale = 1e18 (WETH), so both cancel: quote = baseAmount*1e18*1e18/(1e6*ask).
        uint256 expected = FixedPointMathLib.fullMulDiv(baseAmount * 1e18, 1e18, BASE_SCALE * askPrice);

        assertEq(market.quoteCollateral(address(weth), baseAmount), expected, "quote did not floor");
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
