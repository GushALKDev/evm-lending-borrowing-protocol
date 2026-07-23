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
 * @title AbsorbLiquidationTest
 * @notice Phase 6 coverage: isLiquidatable at price + conf, the three absorb settlements (surplus,
 *         exact, shortfall) with explicit bad debt, multi-collateral absorb, the storefront discount
 *         quote, buyCollateral gated on the reserve deficit, and the ABSORB/BUY pause flags.
 * @dev Reference position: 10 WETH at 2,000 USD, liquidateCF 85%, LF 93%, storeFront 50%, base 1 USD.
 */
contract AbsorbLiquidationTest is Test {
    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice"); // borrower to be absorbed
    address internal bob = makeAddr("bob"); // supply side
    address internal carol = makeAddr("carol"); // liquidator / buyer

    uint8 internal constant PAUSE_ABSORB = 1 << 3;
    uint8 internal constant PAUSE_BUY = 1 << 4;

    uint128 internal constant WETH_CAP = 1_000e18;

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        // Lower targetReserves so buyCollateral is reachable after a modest supply.
        cfg.targetReserves = 1_000_000e6;

        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);

        market = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(base), 1e18, 0);
        oracle.setPrice(address(weth), 2_000e18, 0);

        base.mint(bob, 1_000_000e6);
        base.mint(carol, 1_000_000e6);
        weth.mint(alice, 100e18);

        vm.startPrank(alice);
        weth.approve(address(market), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        base.approve(address(market), type(uint256).max);
        vm.prank(carol);
        base.approve(address(market), type(uint256).max);

        // Bob funds the pool; alice posts 10 WETH and borrows against it.
        vm.prank(bob);
        market.supply(address(base), 500_000e6);
    }

    /// @dev Alice posts 10 WETH (16,000 USD capacity) and borrows `debt` base.
    function _openPosition(uint256 debt) internal {
        vm.startPrank(alice);
        market.supply(address(weth), 10e18);
        market.withdraw(address(base), debt, new bytes[](0));
        vm.stopPrank();
    }

    function _setWethPrice(uint256 price18) internal {
        oracle.setPrice(address(weth), price18, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          ELIGIBILITY (6.1)
    //////////////////////////////////////////////////////////////*/

    function test_isLiquidatable_falseWhenHealthy() public {
        _openPosition(15_000e6);
        assertFalse(market.isLiquidatable(alice), "healthy position not liquidatable");
    }

    function test_isLiquidatable_trueBelowThreshold() public {
        _openPosition(15_000e6);
        // liqCapacity = 10 * 1,760 * 0.85 = 14,960 < 15,000 debt.
        _setWethPrice(1_760e18);
        assertTrue(market.isLiquidatable(alice), "position below liq threshold");
    }

    function test_isLiquidatable_usesHighEdgeOfConfidenceBand() public {
        _openPosition(15_000e6);
        // Mid 1,760 is liquidatable, but conf pushes the high edge to 1,800: 10*1,800*0.85 = 15,300 > 15,000.
        oracle.setPrice(address(weth), 1_760e18, 40e18);
        assertFalse(market.isLiquidatable(alice), "high edge of the band keeps it healthy");
    }

    function test_absorb_revertsWhenNotLiquidatable() public {
        _openPosition(15_000e6);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingMarket.NotLiquidatable.selector, alice, uint256(15_000e18), uint256(17_000e18)
            )
        );
        market.absorb(alice, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                        ABSORB SETTLEMENT (6.2-6.4)
    //////////////////////////////////////////////////////////////*/

    function test_absorb_surplusCreditsAccountAndSeizesCollateral() public {
        _openPosition(15_000e6);
        _setWethPrice(1_760e18); // seize 17,600, credit 17,600 * 0.93 = 16,368

        int256 reservesBefore = market.getReserves();

        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        // Debt wiped, collateral seized, assetsIn cleared.
        assertEq(market.borrowBalanceOf(alice), 0, "debt wiped");
        assertEq(market.userCollateral(alice, address(weth)), 0, "collateral seized");
        assertEq(market.getAssetsIn(alice), 0, "assetsIn cleared");

        // Surplus credited as base supply: 16,368 - 15,000 = 1,368.
        assertEq(market.balanceOf(alice), 1_368e6, "surplus credited as supply");
        // The seized claim leaves the total; the inventory is now derived from the physical balance.
        assertEq(market.totalsCollateral(address(weth)), 0, "user claim removed from total");
        assertEq(market.getCollateralReserves(address(weth)), 10e18, "seized inventory held by protocol");
        assertEq(weth.balanceOf(address(market)), 10e18, "tokens still custodied");
        // Reserves fell by the credit (16,368).
        assertEq(reservesBefore - market.getReserves(), 16_368e6, "reserves fall by credit");
    }

    function test_absorb_shortfallRecognizesBadDebtAndZeroesAccount() public {
        _openPosition(15_000e6);
        _setWethPrice(1_400e18); // seize 14,000, credit 14,000 * 0.93 = 13,020 < 15,000

        int256 reservesBefore = market.getReserves();

        vm.recordLogs();
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        assertEq(market.borrowBalanceOf(alice), 0, "debt wiped");
        assertEq(market.balanceOf(alice), 0, "account zeroed, no surplus");
        // Reserves fall by the full debt (15,000): the 1,980 shortfall is recognized bad debt.
        assertEq(reservesBefore - market.getReserves(), 15_000e6, "reserves fall by full debt");
    }

    function test_absorb_exactLeavesAccountAndReservesFlat() public {
        _openPosition(9_300e6);
        // At 1,000: credit = 10 * 1,000 * 0.93 = 9,300 == debt; liqCapacity = 8,500 < 9,300 eligible.
        _setWethPrice(1_000e18);

        int256 reservesBefore = market.getReserves();
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        assertEq(market.borrowBalanceOf(alice), 0, "debt wiped");
        assertEq(market.balanceOf(alice), 0, "account exactly zeroed");
        assertEq(reservesBefore - market.getReserves(), 9_300e6, "reserves fall by exactly the debt");
    }

    function test_absorb_emitsDebtAndCollateralEvents() public {
        _openPosition(15_000e6);
        _setWethPrice(1_400e18);

        vm.expectEmit(true, true, true, true);
        emit ILendingMarket.AbsorbCollateral(carol, alice, address(weth), 10e18, 14_000e18);
        vm.expectEmit(true, true, false, true);
        emit ILendingMarket.AbsorbDebt(carol, alice, 15_000e6, 1_980e6);

        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                          MULTI-COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_absorb_seizesEveryHeldCollateral() public {
        // Redeploy with a second collateral (wBTC) to exercise the seize loop over two assets.
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "wBTC", 8);
        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        cfg.targetReserves = 1_000_000e6;
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](2);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        collaterals[1] = MarketBuilder.collateral(address(wbtc), 8, 1_000e8);
        LendingMarketHarness m2 = new LendingMarketHarness(cfg, collaterals);

        oracle.setPrice(address(wbtc), 40_000e18, 0);

        base.mint(bob, 1_000_000e6);
        weth.mint(alice, 100e18);
        wbtc.mint(alice, 10e8);
        vm.startPrank(alice);
        weth.approve(address(m2), type(uint256).max);
        wbtc.approve(address(m2), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        base.approve(address(m2), type(uint256).max);
        m2.supply(address(base), 800_000e6);
        vm.stopPrank();

        // 1 WETH (2,000) + 1 wBTC (40,000): capacity = 42,000 * 0.80 = 33,600.
        vm.startPrank(alice);
        m2.supply(address(weth), 1e18);
        m2.supply(address(wbtc), 1e8);
        m2.withdraw(address(base), 33_000e6, new bytes[](0));
        vm.stopPrank();

        // Crash wBTC (the dominant leg) so the position is liquidatable.
        oracle.setPrice(address(wbtc), 10_000e18, 0);
        assertTrue(m2.isLiquidatable(alice), "eligible after crash");

        vm.prank(carol);
        m2.absorb(alice, new bytes[](0));

        assertEq(m2.userCollateral(alice, address(weth)), 0, "WETH seized");
        assertEq(m2.userCollateral(alice, address(wbtc)), 0, "wBTC seized");
        assertEq(m2.getAssetsIn(alice), 0, "both bits cleared");
        assertEq(m2.borrowBalanceOf(alice), 0, "debt wiped");
    }

    /*//////////////////////////////////////////////////////////////
                        QUOTE + BUY (6.5-6.6)
    //////////////////////////////////////////////////////////////*/

    function test_quoteCollateral_appliesStorefrontDiscount() public view {
        // discount = 0.50 * (1 - 0.93) = 3.5%; askPrice = 2,000 * 0.965 = 1,930.
        // quote for 1,930 base = 1,930 * 1 / 1,930 = 1 WETH.
        uint256 quote = market.quoteCollateral(address(weth), 1_930e6);
        assertEq(quote, 1e18, "quote reflects the 3.5% discount");
    }

    function test_buyCollateral_sellsInventoryWhenReservesLow() public {
        // Absorb first so the protocol holds 10 WETH of inventory.
        _openPosition(15_000e6);
        _setWethPrice(1_760e18);
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        // Restore price; reserves are below target (1,000,000), so the sale is open.
        _setWethPrice(2_000e18);
        assertLt(market.getReserves(), int256(uint256(1_000_000e6)), "reserves below target");

        uint256 wethBefore = weth.balanceOf(carol);
        // askPrice = 1,930; buy with 19,300 base → 10 WETH.
        vm.prank(carol);
        market.buyCollateral(address(weth), 10e18, 19_300e6, carol, new bytes[](0));

        assertEq(weth.balanceOf(carol) - wethBefore, 10e18, "buyer receives discounted collateral");
        assertEq(market.getCollateralReserves(address(weth)), 0, "seized inventory drained");
    }

    function test_buyCollateral_revertsWhenReservesAtTarget() public {
        // No absorb, no inventory needed: reserves start at the target-covered supply level.
        // Bob supplied 500,000; reserves == 0 (cash 500k = supply 500k). targetReserves is 1,000,000,
        // so reserves < target and the not-for-sale guard should NOT fire here — instead we raise
        // reserves above target by donating base, then expect NotForSale.
        base.mint(address(market), 1_500_000e6);
        assertGe(market.getReserves(), int256(uint256(1_000_000e6)), "reserves above target");

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.NotForSale.selector, market.getReserves(), uint256(1_000_000e6))
        );
        market.buyCollateral(address(weth), 0, 1_000e6, carol, new bytes[](0));
    }

    function test_buyCollateral_slippageGuard() public {
        _openPosition(15_000e6);
        _setWethPrice(1_760e18);
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
        _setWethPrice(2_000e18);

        // Demand more than the quote yields.
        uint256 quote = market.quoteCollateral(address(weth), 1_930e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.TooMuchSlippage.selector, quote, quote + 1));
        market.buyCollateral(address(weth), quote + 1, 1_930e6, carol, new bytes[](0));
    }

    function test_buyCollateral_revertsOnInsufficientInventory() public {
        _openPosition(15_000e6);
        _setWethPrice(1_760e18);
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
        _setWethPrice(2_000e18);

        // Ask for more collateral than the 10 WETH of seized inventory.
        uint256 quote = market.quoteCollateral(address(weth), 100_000e6);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InsufficientInventory.selector, address(weth), quote, 10e18)
        );
        market.buyCollateral(address(weth), 0, 100_000e6, carol, new bytes[](0));
    }

    function test_buyCollateral_revertsOnZeroRecipient() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidRecipient.selector, address(0)));
        market.buyCollateral(address(weth), 0, 1_000e6, address(0), new bytes[](0));
    }

    function test_buyCollateral_revertsOnZeroBaseAmount() public {
        vm.prank(carol);
        vm.expectRevert(ILendingMarket.ZeroAmount.selector);
        market.buyCollateral(address(weth), 0, 0, carol, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                        ROUND-TRIP RESERVES (6.8)
    //////////////////////////////////////////////////////////////*/

    function test_absorbThenSell_neverReducesReservesAtStablePrices() public {
        // Absorb at the same price the collateral is later sold at: the discount round trip must
        // leave reserves no lower than before the absorb (the protocol keeps the penalty margin).
        _openPosition(15_000e6);
        // Keep price at 2,000 but make the account liquidatable by shrinking capacity: borrow more.
        // Instead, drop to a price that is liquidatable and buy back at that same price.
        _setWethPrice(1_760e18);

        int256 reservesBeforeAbsorb = market.getReserves();
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        // Sell all 10 WETH at the same 1,760 price. askPrice = 1,760 * 0.965 = 1,698.4.
        // proceeds to drain 10 WETH: baseAmount = 10 * 1,698.4 = 16,984.
        vm.prank(carol);
        market.buyCollateral(address(weth), 10e18, 16_984e6, carol, new bytes[](0));

        assertEq(market.getCollateralReserves(address(weth)), 0, "all seized inventory sold");
        assertGe(market.getReserves(), reservesBeforeAbsorb, "round trip never reduces reserves");
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE FLAGS (6.7)
    //////////////////////////////////////////////////////////////*/

    function test_absorb_pausable() public {
        _openPosition(15_000e6);
        _setWethPrice(1_760e18);

        vm.prank(guardian);
        market.setPauseFlags(PAUSE_ABSORB);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, PAUSE_ABSORB));
        market.absorb(alice, new bytes[](0));
    }

    function test_buyCollateral_pausable() public {
        vm.prank(guardian);
        market.setPauseFlags(PAUSE_BUY);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.Paused.selector, PAUSE_BUY));
        market.buyCollateral(address(weth), 0, 1_000e6, carol, new bytes[](0));
    }

    /*//////////////////////////////////////////////////////////////
                 COLLATERAL RESERVES SEMANTICS (ADR-7)
    //////////////////////////////////////////////////////////////*/

    /// @dev Regression pin for ADR-7. With a live user claim sitting next to seized inventory, a buy
    ///      whose quote exceeds the seized inventory reverts even though it would fit inside the raw
    ///      total under the old pool-wide semantics. This is the exact case that could have sold
    ///      user-owned collateral.
    function test_buyCollateral_cannotSellUserOwnedCollateral() public {
        // Bob posts 10 WETH as a live claim that must never be sellable through buyCollateral.
        weth.mint(bob, 10e18);
        vm.startPrank(bob);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), 10e18);
        vm.stopPrank();

        // Alice is absorbed: her 10 WETH become seized inventory, her claim leaves the total.
        _openPosition(15_000e6);
        _setWethPrice(1_760e18);
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
        _setWethPrice(2_000e18);

        // Total is bob's live claim (10 WETH); seized inventory is also 10 WETH; balance is 20 WETH.
        assertEq(market.totalsCollateral(address(weth)), 10e18, "total is the live user claim only");
        assertEq(market.getCollateralReserves(address(weth)), 10e18, "seized inventory only");
        assertEq(weth.balanceOf(address(market)), 20e18, "physical balance holds both");

        // Buying 11 WETH fits the old 20 WETH raw total but exceeds the 10 WETH seized inventory.
        uint256 quote11 = market.quoteCollateral(address(weth), 21_230e6);
        assertGt(quote11, 10e18, "quote exceeds seized inventory");
        assertLe(quote11, 20e18, "but would fit the old raw total");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.InsufficientInventory.selector, address(weth), quote11, 10e18)
        );
        market.buyCollateral(address(weth), 0, 21_230e6, carol, new bytes[](0));

        // Buying exactly the seized inventory succeeds, and bob can still withdraw his full claim.
        vm.prank(carol);
        market.buyCollateral(address(weth), 10e18, 19_300e6, carol, new bytes[](0));
        assertEq(market.getCollateralReserves(address(weth)), 0, "seized inventory drained");

        vm.prank(bob);
        market.withdraw(address(weth), 10e18, new bytes[](0));
        assertEq(weth.balanceOf(bob), 10e18, "user claim fully recoverable");
    }

    /// @dev The supply cap bounds user claims only. Seized inventory does not consume cap room, so a
    ///      cap-filling deposit is accepted after an absorb that would have blocked it under the old
    ///      semantics where seized inventory still counted against the cap.
    function test_supplyCap_countsUserClaimsNotSeizedInventory() public {
        // Alice fills nearly all of the 1,000 WETH cap, then borrows and is absorbed.
        weth.mint(alice, 900e18); // top up beyond the 100 WETH minted in setUp
        vm.prank(alice);
        market.supply(address(weth), 990e18);
        vm.prank(alice);
        market.withdraw(address(base), 15_000e6, new bytes[](0));
        _setWethPrice(15e18); // 990 WETH * 15 * 0.85 = 12,622 capacity < 15,000 debt: liquidatable
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));

        // Absorb removed alice's 990 WETH claim from the total; the cap is free again.
        assertEq(market.totalsCollateral(address(weth)), 0, "user claims cleared from total");
        assertEq(market.getCollateralReserves(address(weth)), 990e18, "990 WETH now seized inventory");

        // A fresh 1,000 WETH deposit fits the cap even though 990 WETH of seized inventory is custodied.
        weth.mint(bob, 1_000e18);
        vm.startPrank(bob);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), 1_000e18);
        vm.stopPrank();
        assertEq(market.totalsCollateral(address(weth)), 1_000e18, "cap counts user claims only");
    }

    /// @dev The full absorb, buyCollateral, withdrawCollateral sequence: the path that was unsafe
    ///      under the old semantics now settles with the withdrawing user's claim intact throughout.
    function test_absorbBuyWithdraw_sequenceKeepsUserWhole() public {
        weth.mint(bob, 10e18);
        vm.startPrank(bob);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), 10e18);
        vm.stopPrank();

        _openPosition(15_000e6);
        _setWethPrice(1_760e18);
        vm.prank(carol);
        market.absorb(alice, new bytes[](0));
        _setWethPrice(2_000e18);

        // Drain the seized inventory only.
        vm.prank(carol);
        market.buyCollateral(address(weth), 10e18, 19_300e6, carol, new bytes[](0));
        assertEq(market.getCollateralReserves(address(weth)), 0, "seized inventory sold");

        // Bob withdraws his untouched 10 WETH; the total returns to zero.
        vm.prank(bob);
        market.withdraw(address(weth), 10e18, new bytes[](0));
        assertEq(weth.balanceOf(bob), 10e18, "user claim recovered in full");
        assertEq(market.totalsCollateral(address(weth)), 0, "total back to zero");
    }
}
