// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// solhint-disable no-console
// This suite includes a reporting test that deliberately logs the measured precision gap; the
// console output is the point of test_indexScale_reportErrorAcrossPositionSizes.

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";

/**
 * @title IndexPrecisionTest
 * @notice Quantifies what the 1e15 index scale actually costs against a 1e27 (RAY) reference.
 * @dev Motivation: RAY scaled indexes (the Aave choice) carry more digits, so the question is
 *      whether those digits are observable at this protocol's 6 decimal base. They are not: the per
 *      second rate is already quantized at 1e18, so a 1e15 index carries more resolution than the
 *      rate can supply, and presentValue then quantizes to base units well before the index scale
 *      matters. The residual is one base unit at most, always in the protocol favorable direction,
 *      at any position size.
 *
 *      This analysis is coupled to the base asset having 6 decimals (see the note in
 *      docs/05-implementation.md, Section 2).
 */
contract IndexPrecisionTest is Test {
    uint256 internal constant BASE_INDEX_SCALE = 1e15;
    uint256 internal constant RAY = 1e27;

    // 4% APR per second at 1e18 scale.
    uint256 internal constant RATE_4_PCT = 1268391679;

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();
        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), address(this), guardian);
        ILendingMarket.CollateralConfig[] memory noCollateral = new ILendingMarket.CollateralConfig[](0);
        market = new LendingMarketHarness(cfg, noCollateral);
    }

    /**
     * @notice The 1e15 index never credits a supplier more than a RAY scaled index would.
     * @dev Accrues at 4% APR over an arbitrary window, then compares present value against the same
     *      computation carried at 1e27. Two facts matter and are asserted separately: the coarse
     *      index never reads high (so the scale choice is never a leak), and the gap is at most one
     *      base unit (so it is never economically visible).
     *
     *      The residual comes from the final division quantizing to base units, not from the index
     *      itself: presentValue divides by 1e15 where the reference divides by 1e27, and at dust
     *      sized principals those two truncations can land one wei apart.
     */
    function testFuzz_indexScale_neverFavorsTheSupplier(uint104 principal, uint32 elapsed) public {
        // Full domain including dust, up to 100M USDC.
        principal = uint104(bound(principal, 1, 100_000_000e6));
        elapsed = uint32(bound(elapsed, 1, 365 days));

        irm.setRates(RATE_4_PCT, RATE_4_PCT);
        vm.warp(block.timestamp + elapsed);
        market.accrue();

        // The same accrual carried at RAY precision, floored identically at each step.
        uint256 rayIndex = RAY + (RAY * (RATE_4_PCT * uint256(elapsed))) / 1e18;

        uint256 actual = market.exposedPresentValueSupply(principal);
        uint256 refValue = (uint256(principal) * rayIndex) / RAY;

        // Direction first: the coarse scale must never over-credit. This is the load bearing half.
        assertLe(actual, refValue, "1e15 index credited more than the RAY reference");

        // Magnitude second: the gap is bounded by a single base unit (1e-6 USDC).
        assertLe(refValue - actual, 1, "index scale cost exceeded one base unit");
    }

    /**
     * @notice The one base unit gap is a rounding artefact, not a function of position size.
     * @dev Worth pinning explicitly because the intuition is wrong: the gap does not shrink as
     *      positions grow. It appears whenever principal * index does not land on an exact multiple
     *      of the scale, which can happen at any magnitude. What is bounded is the gap itself (one
     *      base unit) and its direction (never toward the supplier), both asserted above.
     *
     *      The relative error is what actually scales: at 1e-6 USDC absolute, a 100 USDC position
     *      loses at most 1e-8 of its value, and a 1M USDC position at most 1e-12.
     */
    function testFuzz_indexScale_relativeErrorShrinksWithSize(uint104 principal, uint32 elapsed) public {
        principal = uint104(bound(principal, 100e6, 100_000_000e6));
        elapsed = uint32(bound(elapsed, 1, 365 days));

        irm.setRates(RATE_4_PCT, RATE_4_PCT);
        vm.warp(block.timestamp + elapsed);
        market.accrue();

        uint256 rayIndex = RAY + (RAY * (RATE_4_PCT * uint256(elapsed))) / 1e18;
        uint256 actual = market.exposedPresentValueSupply(principal);
        uint256 refValue = (uint256(principal) * rayIndex) / RAY;

        // Absolute gap stays at one base unit regardless of size.
        assertLe(refValue - actual, 1, "absolute gap exceeded one base unit");

        // Relative gap is below one part per billion for any position at or above minBorrow.
        assertLe((refValue - actual) * 1e9, refValue, "relative error exceeded 1e-9");
    }

    /**
     * @notice Pins the assumption the scale choice rests on: the base asset has 6 decimals.
     * @dev The 1e15 index scale is only free of precision cost because presentValue quantizes to
     *      6 decimal base units, which is far coarser than the index. An 18 decimal base would have
     *      12 more orders of resolution to preserve and would need a wider scale (see the note in
     *      docs/05-implementation.md, Section 2). This test fails loudly if the base ever widens.
     */
    function test_indexScale_assumesSixDecimalBase() public view {
        assertEq(market.BASE_SCALE(), 1e6, "index scale analysis assumes a 6 decimal base asset");
    }

    /**
     * @notice Reports the absolute gap across position sizes, round and non round alike.
     * @dev Reported rather than asserted: these are the numbers that justify the scale choice.
     *      Round powers of ten divide cleanly and show zero gap; the non round sizes are included
     *      precisely so the report does not flatter the result.
     */
    function test_indexScale_reportErrorAcrossPositionSizes() public {
        irm.setRates(RATE_4_PCT, RATE_4_PCT);
        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (uint64 supplyIndex,) = market.getIndexes();
        uint256 rayIndex = RAY + (RAY * (RATE_4_PCT * uint256(365 days))) / 1e18;

        // The two indexes agree digit for digit: the RAY trailing zeros are padding, not signal.
        console2.log("supply index (1e15 scale):", supplyIndex);
        console2.log("ref index (1e27):        ", rayIndex);

        uint104[8] memory sizes = [
            uint104(100e6), // 100 USDC (minBorrow), round
            uint104(100_000_892), // 100.000892 USDC, the fuzzer's counterexample
            uint104(10_000e6), // 10k USDC, round
            uint104(33_333_333_333), // 33,333.333333 USDC, non round
            uint104(1_000_000e6), // 1M USDC, round
            uint104(7_777_777_777_777), // 7,777,777.777777 USDC, non round
            uint104(100_000_000e6), // 100M USDC, round
            uint104(100_000_000_000e6) // 100B USDC, round
        ];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 actual = market.exposedPresentValueSupply(sizes[i]);
            uint256 refValue = (uint256(sizes[i]) * rayIndex) / RAY;
            uint256 diff = actual > refValue ? actual - refValue : refValue - actual;

            console2.log("position (base units):", sizes[i]);
            console2.log("  error (base units): ", diff);
        }
    }
}
