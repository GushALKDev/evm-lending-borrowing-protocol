// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";

/**
 * @title AccrualOverflowTest
 * @notice Probes the rate times elapsed product in _accrue against an adversarial rate model.
 * @dev The product is computed in plain uint256 before reaching fullMulDiv, so it is not covered by
 *      that helper's 512 bit intermediate. IInterestRateModel is specified as total over uint256
 *      (Guide 5, Section 3.2), so the market cannot assume the value is small.
 */
contract AccrualOverflowTest is Test {
    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockInterestRateModel internal irm;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        market = new LendingMarketHarness(address(base), address(irm));
    }

    /// @dev A rate large enough that rate * elapsed exceeds uint256 reverts on the multiplication.
    function test_accrue_revertsWhenRateTimesElapsedOverflows() public {
        uint256 elapsed = 365 days;
        // Smallest rate whose product with elapsed exceeds uint256.
        uint256 overflowingRate = type(uint256).max / elapsed + 1;

        irm.setRates(overflowingRate, overflowingRate);
        vm.warp(block.timestamp + elapsed);

        // Checked arithmetic catches it: a panic, not a corrupted index.
        vm.expectRevert();
        market.accrue();
    }

    /// @dev Just below the overflow threshold the multiplication succeeds and the cast catches it.
    function test_accrue_revertsOnIndexCastWhenRateIsMerelyAbsurd() public {
        uint256 elapsed = 365 days;
        uint256 hugeButSafeRate = type(uint256).max / elapsed - 1;

        irm.setRates(hugeButSafeRate, hugeButSafeRate);
        vm.warp(block.timestamp + elapsed);

        // The product fits, but the resulting index cannot fit in uint64: SafeCastLib reverts.
        vm.expectRevert();
        market.accrue();
    }

    /// @dev The realistic domain is nowhere near either boundary.
    function test_accrue_realisticRatesAreFarFromTheBound() public {
        uint256 elapsed = 365 days;
        // 1000% APR per second, far above anything the reference curve produces.
        uint256 extremeRate = 3.17e11;

        irm.setRates(extremeRate, extremeRate);
        vm.warp(block.timestamp + elapsed);

        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertGt(supplyIndex, 0, "supply index accrued");
        assertGt(borrowIndex, 0, "borrow index accrued");

        // Headroom against the overflow threshold is over 50 orders of magnitude.
        assertLt(extremeRate, type(uint256).max / elapsed / 1e50, "extreme rate still far from the bound");
    }
}
