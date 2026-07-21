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
 * @title SupplyWithdrawTest
 * @notice Phase 3 coverage: base supply/withdraw, collateral supply/withdraw, ERC20 transfers,
 *         and the SUPPLY/TRANSFER/WITHDRAW pause flags with the guardian role.
 */
contract SupplyWithdrawTest is Test {
    uint8 internal constant PAUSE_SUPPLY = 1 << 0;
    uint8 internal constant PAUSE_TRANSFER = 1 << 1;
    uint8 internal constant PAUSE_WITHDRAW = 1 << 2;

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint128 internal constant WETH_CAP = 1_000e18;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);

        market = new LendingMarketHarness(cfg, collaterals);

        base.mint(alice, 1_000_000e6);
        base.mint(bob, 1_000_000e6);
        weth.mint(alice, 100e18);

        vm.prank(alice);
        base.approve(address(market), type(uint256).max);
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.prank(alice);
        weth.approve(address(market), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            SUPPLY BASE (3.1)
    //////////////////////////////////////////////////////////////*/

    function test_supplyBase_creditsBalanceAndPullsTokens() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        assertEq(market.balanceOf(alice), 10_000e6, "balance credited");
        assertEq(base.balanceOf(address(market)), 10_000e6, "tokens pulled");
        assertEq(market.totalSupply(), 10_000e6, "total supply");
    }

    function test_supplyBase_emitsSupplyAndTransfer() public {
        // The domain event comes first, then the ERC20 mint mirror.
        vm.expectEmit(true, false, false, true, address(market));
        emit ILendingMarket.Supply(alice, 10_000e6);
        vm.expectEmit(true, true, true, true, address(market));
        emit ILendingMarket.Transfer(address(0), alice, 10_000e6);

        vm.prank(alice);
        market.supply(address(base), 10_000e6);
    }

    function test_supplyBase_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ILendingMarket.ZeroAmount.selector);
        market.supply(address(base), 0);
    }

    function test_supplyBase_accrualGrowsBalance() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        // Drive a supply rate and warp: the rebasing balance should grow with no new deposit.
        irm.setRates(0, 1e10);
        vm.warp(block.timestamp + 365 days);
        market.accrue();

        assertGt(market.balanceOf(alice), 10_000e6, "balance rebased up");
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW BASE (3.3)
    //////////////////////////////////////////////////////////////*/

    function test_withdrawBase_returnsTokensAndClearsBalance() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        uint256 balanceBefore = base.balanceOf(alice);
        vm.prank(alice);
        market.withdraw(address(base), 4_000e6, new bytes[](0));

        assertEq(market.balanceOf(alice), 6_000e6, "balance decremented");
        assertEq(base.balanceOf(alice), balanceBefore + 4_000e6, "tokens returned");
    }

    function test_withdrawBase_fullWithdrawalZeroesBalance() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(alice);
        market.withdraw(address(base), 10_000e6, new bytes[](0));

        assertEq(market.balanceOf(alice), 0, "balance zeroed");
        assertEq(market.getPrincipal(alice), 0, "principal zeroed");
    }

    /// @dev Phase 3 forbids crossing below zero; borrowing lands in Phase 4.
    function test_withdrawBase_revertsWhenItWouldBorrow() public {
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InsufficientBalance.selector, alice, 1_000e6, 1_500e6));
        market.withdraw(address(base), 1_500e6, new bytes[](0));
    }

    function test_withdrawBase_revertsWhenCashInsufficient() public {
        // Alice supplies, then the market's cash is drained by a direct principal edit that leaves
        // supply on the books but no cash (simulating utilization near 100%).
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        // Move the cash out from under the market to force the cash check.
        vm.prank(address(market));
        base.transfer(bob, 9_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InsufficientCash.selector, 5_000e6, 1_000e6));
        market.withdraw(address(base), 5_000e6, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                        SUPPLY COLLATERAL (3.2)
    //////////////////////////////////////////////////////////////*/

    function test_supplyCollateral_updatesLedgersAndBitmap() public {
        vm.prank(alice);
        market.supply(address(weth), 10e18);

        assertEq(market.userCollateral(alice, address(weth)), 10e18, "user collateral");
        assertEq(market.totalsCollateral(address(weth)), 10e18, "total collateral");
        assertEq(market.getAssetsIn(alice), 1, "assetsIn bit 0 set");
        assertEq(weth.balanceOf(address(market)), 10e18, "tokens custodied");
    }

    function test_supplyCollateral_enforcesSupplyCap() public {
        weth.mint(alice, WETH_CAP);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.SupplyCapExceeded.selector, address(weth), WETH_CAP, WETH_CAP + 1e18)
        );
        market.supply(address(weth), WETH_CAP + 1e18);
    }

    function test_supplyCollateral_revertsOnUnknownAsset() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.UnknownAsset.selector, address(stray)));
        market.supply(address(stray), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAW COLLATERAL (3.4)
    //////////////////////////////////////////////////////////////*/

    function test_withdrawCollateral_returnsAndClearsBitmapOnZero() public {
        vm.prank(alice);
        market.supply(address(weth), 10e18);

        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        market.withdraw(address(weth), 10e18, new bytes[](0));

        assertEq(market.userCollateral(alice, address(weth)), 0, "collateral removed");
        assertEq(market.getAssetsIn(alice), 0, "assetsIn bit cleared");
        assertEq(weth.balanceOf(alice), before + 10e18, "tokens returned");
    }

    function test_withdrawCollateral_partialKeepsBitmapSet() public {
        vm.prank(alice);
        market.supply(address(weth), 10e18);
        vm.prank(alice);
        market.withdraw(address(weth), 4e18, new bytes[](0));

        assertEq(market.userCollateral(alice, address(weth)), 6e18, "partial balance");
        assertEq(market.getAssetsIn(alice), 1, "bit still set");
    }

    function test_withdrawCollateral_revertsOnInsufficientBalance() public {
        vm.prank(alice);
        market.supply(address(weth), 5e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InsufficientCollateral.selector, alice, address(weth), 5e18, 6e18)
        );
        market.withdraw(address(weth), 6e18, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                          ERC20 TRANSFER (3.5)
    //////////////////////////////////////////////////////////////*/

    function test_transfer_movesSupplyBetweenAccounts() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        vm.prank(alice);
        market.transfer(bob, 3_000e6);

        assertEq(market.balanceOf(alice), 7_000e6, "sender debited");
        assertEq(market.balanceOf(bob), 3_000e6, "receiver credited");
    }

    function test_transfer_revertsWhenItWouldPushSenderNegative() public {
        vm.prank(alice);
        market.supply(address(base), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.TransferWouldBorrow.selector, alice, 1_000e6, 2_000e6));
        market.transfer(bob, 2_000e6);
    }

    function test_transferFrom_spendsAllowance() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(alice);
        market.approve(bob, 5_000e6);

        vm.prank(bob);
        market.transferFrom(alice, bob, 3_000e6);

        assertEq(market.balanceOf(bob), 3_000e6, "moved to bob");
        assertEq(market.allowance(alice, bob), 2_000e6, "allowance spent");
    }

    function test_transferFrom_revertsOnInsufficientAllowance() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(alice);
        market.approve(bob, 1_000e6);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InsufficientAllowance.selector, alice, bob, 1_000e6, 2_000e6)
        );
        market.transferFrom(alice, bob, 2_000e6);
    }

    function test_transferFrom_infiniteAllowanceIsNotSpent() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(alice);
        market.approve(bob, type(uint256).max);

        vm.prank(bob);
        market.transferFrom(alice, bob, 3_000e6);

        assertEq(market.allowance(alice, bob), type(uint256).max, "infinite allowance untouched");
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE FLAGS (3.6)
    //////////////////////////////////////////////////////////////*/

    function test_pause_ownerCanSetAndClear() public {
        vm.prank(owner);
        market.setPauseFlags(PAUSE_SUPPLY);
        assertEq(market.getMarketState().pauseFlags, PAUSE_SUPPLY, "flag set");

        vm.prank(owner);
        market.setPauseFlags(0);
        assertEq(market.getMarketState().pauseFlags, 0, "flag cleared");
    }

    function test_pause_guardianCanAddButNotClear() public {
        vm.prank(guardian);
        market.setPauseFlags(PAUSE_SUPPLY);
        assertEq(market.getMarketState().pauseFlags, PAUSE_SUPPLY, "guardian set");

        // Guardian may add another flag.
        vm.prank(guardian);
        market.setPauseFlags(PAUSE_SUPPLY | PAUSE_WITHDRAW);
        assertEq(market.getMarketState().pauseFlags, PAUSE_SUPPLY | PAUSE_WITHDRAW, "guardian added");

        // Guardian may not clear any flag.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingMarket.GuardianCannotUnpause.selector, PAUSE_SUPPLY | PAUSE_WITHDRAW, PAUSE_SUPPLY
            )
        );
        market.setPauseFlags(PAUSE_SUPPLY);
    }

    function test_pause_revertsForNonOwnerNonGuardian() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Unauthorized.selector, alice));
        market.setPauseFlags(PAUSE_SUPPLY);
    }

    function test_pause_supplyBlocksSupply() public {
        vm.prank(owner);
        market.setPauseFlags(PAUSE_SUPPLY);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, PAUSE_SUPPLY));
        market.supply(address(base), 1_000e6);
    }

    function test_pause_withdrawBlocksWithdraw() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(owner);
        market.setPauseFlags(PAUSE_WITHDRAW);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, PAUSE_WITHDRAW));
        market.withdraw(address(base), 1_000e6, new bytes[](0));
    }

    function test_pause_transferBlocksTransfer() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);
        vm.prank(owner);
        market.setPauseFlags(PAUSE_TRANSFER);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, PAUSE_TRANSFER));
        market.transfer(bob, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                          REPAY-LIKE SENTINEL
    //////////////////////////////////////////////////////////////*/

    /// @dev With no debt, the full-repay sentinel has nothing to repay and reverts.
    function test_supplyBase_maxSentinelRevertsWithoutDebt() public {
        vm.prank(alice);
        vm.expectRevert(ILendingMarket.ZeroAmount.selector);
        market.supply(address(base), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          ERC20 METADATA (3.7)
    //////////////////////////////////////////////////////////////*/

    function test_metadata_matchesLmUSDC() public view {
        assertEq(market.name(), "Lending Market USDC", "name");
        assertEq(market.symbol(), "lmUSDC", "symbol");
        assertEq(market.decimals(), 6, "decimals mirror the base token");
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _cfg() internal view returns (LendingMarket.MarketConfig memory) {
        return MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
    }

    function _oneCollateral(ILendingMarket.CollateralConfig memory c)
        internal
        pure
        returns (ILendingMarket.CollateralConfig[] memory arr)
    {
        arr = new ILendingMarket.CollateralConfig[](1);
        arr[0] = c;
    }

    function test_constructor_revertsWhenBorrowCFNotBelowLiquidateCF() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        c.borrowCollateralFactor = c.liquidateCollateralFactor; // not strictly below
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("borrowCF")));
        new LendingMarketHarness(_cfg(), _oneCollateral(c));
    }

    function test_constructor_revertsOnLiquidationFactorAboveScale() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        c.liquidationFactor = 10_001; // above FACTOR_SCALE
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("liquidationFactor"))
        );
        new LendingMarketHarness(_cfg(), _oneCollateral(c));
    }

    function test_constructor_revertsOnZeroStoreFrontPriceFactor() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        c.storeFrontPriceFactor = 0;
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("storeFrontPriceFactor"))
        );
        new LendingMarketHarness(_cfg(), _oneCollateral(c));
    }

    function test_constructor_revertsOnMismatchedDecimals() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 8, WETH_CAP); // WETH is 18
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("decimals")));
        new LendingMarketHarness(_cfg(), _oneCollateral(c));
    }

    function test_constructor_revertsOnZeroSupplyCap() public {
        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, 0);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("supplyCap")));
        new LendingMarketHarness(_cfg(), _oneCollateral(c));
    }

    function test_constructor_revertsOnZeroOracle() public {
        LendingMarket.MarketConfig memory cfg = _cfg();
        cfg.oracle = address(0);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("oracle")));
        new LendingMarketHarness(cfg, new ILendingMarket.CollateralConfig[](0));
    }

    function test_constructor_revertsOnZeroGuardian() public {
        LendingMarket.MarketConfig memory cfg = _cfg();
        cfg.guardian = address(0);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("guardian")));
        new LendingMarketHarness(cfg, new ILendingMarket.CollateralConfig[](0));
    }

    function test_constructor_revertsOnZeroMinBorrow() public {
        LendingMarket.MarketConfig memory cfg = _cfg();
        cfg.minBorrow = 0;
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("minBorrow")));
        new LendingMarketHarness(cfg, new ILendingMarket.CollateralConfig[](0));
    }

    /*//////////////////////////////////////////////////////////////
                            ETH REFUND
    //////////////////////////////////////////////////////////////*/

    /// @dev withdraw is payable; any msg.value it does not use is swept back to the caller.
    function test_withdraw_refundsExcessValue() public {
        vm.prank(alice);
        market.supply(address(base), 10_000e6);

        vm.deal(alice, 1 ether);
        uint256 before = alice.balance;

        vm.prank(alice);
        market.withdraw{value: 1 ether}(address(base), 1_000e6, new bytes[](0));

        // The mock oracle path is not hit here (base withdrawal, no debt), so the full value returns.
        assertEq(alice.balance, before, "excess ETH refunded");
    }
}
