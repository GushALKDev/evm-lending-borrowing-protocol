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
 * @title ValuationRoundingTest
 * @notice Per-site exact-value tests for the valuation divisions: debt in USD (ceil), borrow and
 *         liquidation capacity (floor), the absorb seize value, credit value and credit in base (floor),
 *         and the constructor's INV-13 coverage bound (ceil). Every expectation is computed here in plain
 *         integer arithmetic, so a flipped direction at any one site fails by one unit.
 * @dev The capacity, eligibility and absorb tests elsewhere assert inequalities, booleans, or allow one
 *      unit of slack, which a flipped direction can pass (docs/tests/06-mutation-checks.md). Prices are
 *      fuzzed at full 1e18 precision rather than at round values, so a quotient is exact only when the
 *      product happens to be a multiple of the divisor; each site also has a fixed case with a known
 *      non-zero remainder.
 */
contract ValuationRoundingTest is Test {
    uint256 internal constant FACTOR_SCALE = 10_000;
    uint256 internal constant BASE_SCALE = 1e6; // USDC 6-dec base
    uint256 internal constant WETH_SCALE = 1e18;
    uint64 internal constant BASE_INDEX_SCALE = 1e15;

    // MarketBuilder.collateral reference factors.
    uint256 internal constant BORROW_CF = 8000;
    uint256 internal constant LIQUIDATE_CF = 8500;
    uint256 internal constant LIQUIDATION_FACTOR = 9300;

    uint128 internal constant WETH_CAP = 1_000_000e18;

    LendingMarketHarness internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");

    function setUp() public {
        base = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);
        oracle = new MockPriceOracle();

        market = _deploy(MarketBuilder.collateral(address(weth), 18, WETH_CAP));

        oracle.setPrice(address(base), 1e18, 0);
        vm.prank(alice);
        weth.approve(address(market), type(uint256).max);
    }

    /// @dev Deploys a harness market with a single WETH collateral carrying the given config.
    function _deploy(ILendingMarket.CollateralConfig memory c) internal returns (LendingMarketHarness) {
        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(base), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = c;
        return new LendingMarketHarness(cfg, collaterals);
    }

    /// @dev Posts `amount` WETH as alice's collateral through the public supply path.
    function _postCollateral(uint256 amount) internal {
        weth.mint(alice, amount);
        vm.prank(alice);
        market.supply(address(weth), amount);
    }

    /*//////////////////////////////////////////////////////////////
                           DEBT VALUE (CEIL)
    //////////////////////////////////////////////////////////////*/

    /// @notice _debtUSD ceils: debt PV * (basePrice + baseConf) / BASE_SCALE, rounded up.
    function testFuzz_debtUSD_ceilsExactly(uint104 principal, uint64 borrowIndex, uint256 basePrice, uint256 baseConf)
        public
    {
        principal = uint104(bound(principal, 1, 1e18));
        borrowIndex = uint64(bound(borrowIndex, BASE_INDEX_SCALE, 2 * BASE_INDEX_SCALE));
        basePrice = bound(basePrice, 0.5e18, 2e18);
        baseConf = bound(baseConf, 0, basePrice / 50);

        market.setIndexes(BASE_INDEX_SCALE, borrowIndex);
        market.setPrincipal(alice, -int104(principal));
        oracle.setPrice(address(base), basePrice, baseConf);

        uint256 debtPV = (uint256(principal) * borrowIndex + BASE_INDEX_SCALE - 1) / BASE_INDEX_SCALE;
        uint256 expected = (debtPV * (basePrice + baseConf) + BASE_SCALE - 1) / BASE_SCALE;
        assertEq(market.exposedDebtUSD(alice), expected, "debt USD did not ceil");
    }

    /// @notice 3 base units at a base price of 1e18 + 1 are worth 3e12 + 0.000003 USD-wei: ceiled to 3e12 + 1.
    function test_debtUSD_roundsUp() public {
        market.setPrincipal(alice, -3);
        oracle.setPrice(address(base), 1e18 + 1, 0);
        assertEq(market.exposedDebtUSD(alice), 3_000_000_000_001, "debt USD did not ceil");
    }

    /*//////////////////////////////////////////////////////////////
                         CAPACITIES (FLOOR)
    //////////////////////////////////////////////////////////////*/

    /// @notice _borrowCapacity floors: balance * borrowCF * (price - conf) / (1e18 * FACTOR_SCALE).
    function testFuzz_borrowCapacity_floorsExactly(uint256 amount, uint256 price, uint256 conf) public {
        amount = bound(amount, 1, WETH_CAP);
        price = bound(price, 1e15, 1e24);
        conf = bound(conf, 0, price / 50);
        _postCollateral(amount);
        oracle.setPrice(address(weth), price, conf);

        uint256 expected = (amount * BORROW_CF * (price - conf)) / (WETH_SCALE * FACTOR_SCALE);
        assertEq(market.exposedBorrowCapacity(alice), expected, "borrow capacity did not floor");
    }

    /// @notice 1 WETH + 1 wei at a low edge of 1,997 USD: exactly 1,597.6e18 + 1,597.6, floored.
    function test_borrowCapacity_roundsDown() public {
        _postCollateral(1e18 + 1);
        oracle.setPrice(address(weth), 2_000e18, 3e18);
        assertEq(market.exposedBorrowCapacity(alice), 1_597_600_000_000_000_001_597, "borrow capacity did not floor");
    }

    /// @notice _liquidationCapacity floors: balance * liquidateCF * (price + conf) / (1e18 * FACTOR_SCALE).
    function testFuzz_liquidationCapacity_floorsExactly(uint256 amount, uint256 price, uint256 conf) public {
        amount = bound(amount, 1, WETH_CAP);
        price = bound(price, 1e15, 1e24);
        conf = bound(conf, 0, price / 50);
        _postCollateral(amount);
        oracle.setPrice(address(weth), price, conf);

        uint256 expected = (amount * LIQUIDATE_CF * (price + conf)) / (WETH_SCALE * FACTOR_SCALE);
        assertEq(market.exposedLiquidationCapacity(alice), expected, "liquidation capacity did not floor");
    }

    /// @notice 1 WETH + 1 wei at a high edge of 2,003 USD: exactly 1,702.55e18 + 1,702.55, floored.
    function test_liquidationCapacity_roundsDown() public {
        _postCollateral(1e18 + 1);
        oracle.setPrice(address(weth), 2_000e18, 3e18);
        assertEq(
            market.exposedLiquidationCapacity(alice),
            1_702_550_000_000_000_001_702,
            "liquidation capacity did not floor"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ABSORB CREDIT (FLOOR)
    //////////////////////////////////////////////////////////////*/

    /// @notice The seize loop floors both legs: the AbsorbCollateral value is amount * price / 1e18, and
    ///         the credit it returns is amount * liquidationFactor * price / (1e18 * FACTOR_SCALE).
    function testFuzz_seizeCollateral_floorsSeizeAndCreditValue(uint256 amount, uint256 price) public {
        amount = bound(amount, 1, WETH_CAP);
        price = bound(price, 1e15, 1e24);
        _postCollateral(amount);
        oracle.setPrice(address(weth), price, 0);

        uint256 seizeValue = (amount * price) / WETH_SCALE;
        uint256 expectedCredit = (amount * LIQUIDATION_FACTOR * price) / (WETH_SCALE * FACTOR_SCALE);

        vm.expectEmit(true, true, true, true, address(market));
        emit ILendingMarket.AbsorbCollateral(address(this), alice, address(weth), amount, seizeValue);
        assertEq(market.exposedSeizeCollateral(alice), expectedCredit, "credit value did not floor");
    }

    /// @notice 10 WETH + 3 wei at 1,700 USD + 1 wei: seize value 17,000e18 + 5,110.000...003 and credit
    ///         15,810e18 + 4,752.279, both floored.
    function test_seizeCollateral_roundsDown() public {
        _postCollateral(10e18 + 3);
        oracle.setPrice(address(weth), 1_700e18 + 1, 0);

        vm.expectEmit(true, true, true, true, address(market));
        emit ILendingMarket.AbsorbCollateral(
            address(this), alice, address(weth), 10e18 + 3, 17_000_000_000_000_000_005_110
        );
        assertEq(market.exposedSeizeCollateral(alice), 15_810_000_000_000_000_004_752, "credit value did not floor");
    }

    /// @notice absorb converts the credit to base with a floor, creditBase = creditValue * BASE_SCALE /
    ///         basePrice, and settles against it: a surplus lands as alice's supply, a shortfall as bad debt.
    /// @dev The debt is drawn around creditBase, from just above the liquidation capacity (so the account is
    ///      always absorbable) to as far above creditBase as that is below it, so about half the runs settle
    ///      a surplus and half a shortfall.
    function testFuzz_absorb_creditBaseFloorsExactly(uint256 amount, uint256 price, uint256 basePrice, uint256 debt)
        public
    {
        amount = bound(amount, 1e15, 1_000e18);
        price = bound(price, 1e18, 100_000e18);
        basePrice = bound(basePrice, 0.95e18, 1.05e18);
        _postCollateral(amount);
        oracle.setPrice(address(weth), price, 0);
        oracle.setPrice(address(base), basePrice, 0);

        uint256 creditValue = (amount * LIQUIDATION_FACTOR * price) / (WETH_SCALE * FACTOR_SCALE);
        uint256 creditBase = (creditValue * BASE_SCALE) / basePrice;
        // debtUSD >= debt * basePrice / BASE_SCALE > liquidation capacity for any debt >= minDebt.
        uint256 liqCapacity = (amount * LIQUIDATE_CF * price) / (WETH_SCALE * FACTOR_SCALE);
        uint256 minDebt = (liqCapacity * BASE_SCALE) / basePrice + 1;
        debt = bound(debt, minDebt, creditBase > minDebt ? 2 * creditBase - minDebt : minDebt);
        market.setPrincipal(alice, -int104(uint104(debt)));

        vm.expectEmit(true, true, false, true, address(market));
        emit ILendingMarket.AbsorbDebt(address(this), alice, debt, creditBase < debt ? debt - creditBase : 0);
        market.absorb(alice, new bytes[](0));

        assertEq(market.balanceOf(alice), creditBase > debt ? creditBase - debt : 0, "surplus did not floor");
    }

    /// @notice A 15,000 USDC debt against 10 WETH + 3 wei at 1,700 USD + 1 wei, base at 1.0001 USD: the
    ///         credit converts to 15,808.419158 USDC with a non-zero remainder, leaving a 808.419158 surplus.
    function test_absorb_creditBaseRoundsDown() public {
        _postCollateral(10e18 + 3);
        oracle.setPrice(address(weth), 1_700e18 + 1, 0);
        oracle.setPrice(address(base), 1.0001e18, 0);
        market.setPrincipal(alice, -15_000e6);

        vm.expectEmit(true, true, false, true, address(market));
        emit ILendingMarket.AbsorbDebt(address(this), alice, 15_000e6, 0);
        market.absorb(alice, new bytes[](0));

        assertEq(market.balanceOf(alice), 808_419_158, "surplus did not floor");
    }

    /*//////////////////////////////////////////////////////////////
                    INV-13 COVERAGE BOUND (CEIL)
    //////////////////////////////////////////////////////////////*/

    /// @notice The constructor requires liquidationFactor >= ceil(liquidateCF * (FACTOR_SCALE +
    ///         MAX_CONFIDENCE_BPS) / FACTOR_SCALE): one below the ceiled bound reverts, the bound deploys.
    function testFuzz_coverageBound_ceilsExactly(uint256 liquidateCF, uint256 maxConfBps) public {
        liquidateCF = bound(liquidateCF, 2, 9_000);
        maxConfBps = bound(maxConfBps, 1, 1_000);
        oracle.setMaxConfidenceBps(maxConfBps);

        // At most 9,000 * 1.1 = 9,900, so the bound is always a valid liquidationFactor.
        uint256 coverageBound = (liquidateCF * (FACTOR_SCALE + maxConfBps) + FACTOR_SCALE - 1) / FACTOR_SCALE;

        ILendingMarket.CollateralConfig memory c = MarketBuilder.collateral(address(weth), 18, WETH_CAP);
        c.borrowCollateralFactor = 1;
        c.liquidateCollateralFactor = uint16(liquidateCF);
        c.liquidationFactor = uint16(coverageBound - 1);
        vm.expectRevert(abi.encodeWithSelector(ILendingMarket.InvalidConfiguration.selector, bytes32("coverage")));
        _deploy(c);

        c.liquidationFactor = uint16(coverageBound);
        _deploy(c);
    }
}
