// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {LendingMarketHarness} from "../mocks/LendingMarketHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title MarketAccrualWithRealCurveTest
 * @notice Phase 2 item 2.5: the market accrues against the real InterestRateModel, not a mock.
 * @dev Confirms the immutable wiring works end to end and that accrual driven by the reference
 *      curve advances the indexes in the expected direction and magnitude.
 */
contract MarketAccrualWithRealCurveTest is Test {
    uint64 internal constant BASE_INDEX_SCALE = 1e15;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    uint256 internal constant KINK = 0.8e18;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;
    uint256 internal constant SLOPE_LOW = (0.05e18) / SECONDS_PER_YEAR;
    uint256 internal constant SLOPE_HIGH = (1e18) / SECONDS_PER_YEAR;

    LendingMarketHarness internal market;
    InterestRateModel internal irm;
    MockERC20 internal base;

    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        irm = new InterestRateModel(0, SLOPE_LOW, SLOPE_HIGH, KINK, RESERVE_FACTOR);
        market = new LendingMarketHarness(address(base), address(irm));
    }

    /// @dev At the kink, one year of accrual grows the borrow index by about 4%.
    function test_accrual_atKinkGrowsBorrowIndexByReferenceRate() public {
        // U = 80%: 800 borrowed against 1000 supplied.
        market.setPrincipal(supplier, int104(1_000e6));
        market.setPrincipal(borrower, -int104(800e6));

        assertEq(market.getUtilization(), KINK, "utilization at the kink");

        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();

        // Borrow rate 4% APR, supply rate 4% * 0.8 * 0.9 = 2.88% APR.
        assertApproxEqRel(uint256(borrowIndex), 1.04e15, 0.001e18, "borrow index grew ~4%");
        assertApproxEqRel(uint256(supplyIndex), 1.0288e15, 0.001e18, "supply index grew ~2.88%");
    }

    /// @dev In the jump regime the borrow index grows much faster, as the curve intends.
    function test_accrual_inJumpRegimeGrowsFaster() public {
        // U = 90%: past the kink.
        market.setPrincipal(supplier, int104(1_000e6));
        market.setPrincipal(borrower, -int104(900e6));

        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (, uint64 borrowIndex) = market.getIndexes();

        // Borrow rate 14% APR in the jump regime.
        assertApproxEqRel(uint256(borrowIndex), 1.14e15, 0.001e18, "borrow index grew ~14%");
    }

    /// @dev With no borrows, utilization is zero, the rate is zero, and neither index moves.
    function test_accrual_idleMarketDoesNotAccrue() public {
        market.setPrincipal(supplier, int104(1_000e6));

        vm.warp(block.timestamp + 365 days);
        market.accrue();

        (uint64 supplyIndex, uint64 borrowIndex) = market.getIndexes();
        assertEq(supplyIndex, BASE_INDEX_SCALE, "supply index flat at zero utilization");
        assertEq(borrowIndex, BASE_INDEX_SCALE, "borrow index flat at zero utilization");
    }

    /// @dev The wiring is immutable and points at the deployed model.
    function test_wiring_marketUsesTheRealModel() public view {
        assertEq(address(market.INTEREST_RATE_MODEL()), address(irm), "market points at the real model");
    }
}
