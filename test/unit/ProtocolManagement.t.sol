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
 * @title ProtocolManagementTest
 * @notice Phase 7 coverage: withdrawReserves bounds and access, role separation (owner vs guardian),
 *         and the constructor revert matrix including the INV-13 absorb-coverage condition.
 */
contract ProtocolManagementTest is Test {
    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    uint8 internal constant PAUSE_SUPPLY = 1 << 0;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);

        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);
    }

    /// @dev Seeds positive reserves by donating base: with no principal change, getReserves rises by
    ///      the donated cash. Returns the reserve level created.
    function _seedReserves(uint256 amount) internal returns (uint256) {
        base.mint(address(market), amount);
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW RESERVES (7.2)
    //////////////////////////////////////////////////////////////*/

    function test_withdrawReserves_ownerWithdrawsToTreasury() public {
        uint256 reserves = _seedReserves(50_000e6);
        assertEq(uint256(market.getReserves()), reserves, "reserves seeded");

        vm.prank(owner);
        market.withdrawReserves(treasury, 30_000e6);

        assertEq(base.balanceOf(treasury), 30_000e6, "treasury received the reserves");
        assertEq(uint256(market.getReserves()), 20_000e6, "reserves fell by the withdrawn amount");
    }

    function test_withdrawReserves_emitsEvent() public {
        _seedReserves(10_000e6);
        vm.expectEmit(true, false, false, true, address(market));
        emit ILendingMarket.WithdrawReserves(treasury, 4_000e6);
        vm.prank(owner);
        market.withdrawReserves(treasury, 4_000e6);
    }

    function test_withdrawReserves_revertsForNonOwner() public {
        _seedReserves(10_000e6);
        vm.prank(guardian);
        vm.expectRevert(); // Ownable: caller is not the owner
        market.withdrawReserves(treasury, 1_000e6);
    }

    function test_withdrawReserves_revertsOnZeroRecipient() public {
        _seedReserves(10_000e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidRecipient.selector, address(0)));
        market.withdrawReserves(address(0), 1_000e6);
    }

    /// @dev Bounded by getReserves(): cannot withdraw more than the accounting says exist, even when
    ///      cash is plentiful.
    function test_withdrawReserves_revertsWhenExceedingReserves() public {
        uint256 reserves = _seedReserves(10_000e6);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InsufficientReserves.selector, int256(reserves), uint256(10_001e6))
        );
        market.withdrawReserves(treasury, 10_001e6);
    }

    /// @dev Bounded by cash independently of reserves: a supplier's deposit makes reserves and cash
    ///      diverge (reserves stay at 0 because the supply principal offsets the cash), so a withdrawal
    ///      above reserves is stopped by the reserves bound even though cash would cover it.
    function test_withdrawReserves_reservesBoundBitesBeforeCash() public {
        // Alice supplies: cash = 100k, but reserves = cash + 0 - supplyPV = 0.
        base.mint(alice, 100_000e6);
        vm.startPrank(alice);
        base.approve(address(market), type(uint256).max);
        market.supply(address(base), 100_000e6);
        vm.stopPrank();

        assertEq(uint256(market.getReserves()), 0, "supplier deposit is not reserves");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InsufficientReserves.selector, int256(0), uint256(1)));
        market.withdrawReserves(treasury, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        ROLE SEPARATION (7.3)
    //////////////////////////////////////////////////////////////*/

    function test_roles_guardianCanPauseButNotUnpause() public {
        vm.prank(guardian);
        market.setPauseFlags(PAUSE_SUPPLY);
        assertEq(market.getMarketState().pauseFlags, PAUSE_SUPPLY, "guardian set the flag");

        // Guardian cannot clear it back to zero.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.GuardianCannotUnpause.selector, PAUSE_SUPPLY, uint8(0)));
        market.setPauseFlags(0);
    }

    function test_roles_ownerCanUnpause() public {
        vm.prank(guardian);
        market.setPauseFlags(PAUSE_SUPPLY);

        vm.prank(owner);
        market.setPauseFlags(0);
        assertEq(market.getMarketState().pauseFlags, 0, "owner cleared the flag");
    }

    function test_roles_strangerCannotSetFlags() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Unauthorized.selector, alice));
        market.setPauseFlags(PAUSE_SUPPLY);
    }

    function test_roles_onlyOwnerWithdrawsReserves() public {
        _seedReserves(10_000e6);
        // Even the guardian, the other privileged role, cannot withdraw reserves.
        vm.prank(guardian);
        vm.expectRevert();
        market.withdrawReserves(treasury, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR REVERT MATRIX (7.4)
    //////////////////////////////////////////////////////////////*/

    function _deploy(ILendingMarket.CollateralConfig memory c) internal {
        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = c;
        new LendingMarketHarness(cfg, collaterals);
    }

    /// @dev INV-13: liquidationFactor must dominate liquidateCF widened by the oracle's max confidence.
    ///      At 200 bps and liquidateCF 85%, the floor is 85% * 1.02 = 86.7%; below it reverts.
    function test_constructor_revertsWhenCoverageConditionFails() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        c.liquidationFactor = 8_600; // 86% < 86.7% floor
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("coverage")));
        _deploy(c);
    }

    /// @dev Exactly at the coverage floor is accepted (the bound is >=, rounded up).
    function test_constructor_acceptsCoverageAtTheFloor() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        c.liquidationFactor = 8_670; // 85% * 1.02 = 86.7% exactly
        _deploy(c); // does not revert
    }

    /// @dev The coverage floor tracks the oracle's confidence ceiling: a wider band raises it.
    function test_constructor_coverageFloorTracksOracleConfidence() public {
        oracle.setMaxConfidenceBps(1_000); // 10%: floor becomes 85% * 1.10 = 93.5% > 93%
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        // Reference 93% liquidationFactor now fails against the widened floor.
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("coverage")));
        _deploy(c);
    }

    function test_constructor_revertsOnBorrowCFAboveLiquidateCF() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        c.borrowCollateralFactor = c.liquidateCollateralFactor; // must be strictly below
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("borrowCF")));
        _deploy(c);
    }

    function test_constructor_revertsOnZeroSupplyCap() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        c.supplyCap = 0;
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("supplyCap")));
        _deploy(c);
    }
}
