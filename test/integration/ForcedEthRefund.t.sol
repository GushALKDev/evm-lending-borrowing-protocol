// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MarketBuilder} from "../mocks/MarketBuilder.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockInterestRateModel} from "../mocks/MockInterestRateModel.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {ForceSender, RejectingCaller} from "../mocks/ForcedEth.sol";

/**
 * @title ForcedEthRefundTest
 * @notice ETH that reaches the market outside a call (a selfdestruct, or a balance set directly) must
 *         not change what a caller is refunded. A caller that cannot receive ETH and pays exactly the
 *         Pyth fee must be able to borrow, absorb, and buy collateral while the market holds such ETH,
 *         and an overpaying caller must get back exactly its own excess.
 * @dev Real PythChainlinkOracle over MockPyth charging 1 wei per update; every blob carries two feeds,
 *      and each of these entry points pushes it twice (base and one collateral), so the exact fee is
 *      4 wei. Rates are zeroed.
 */
contract ForcedEthRefundTest is Test {
    MockPyth internal pyth;
    MockChainlinkFeed internal usdcAnchor;
    MockChainlinkFeed internal wethAnchor;
    PythChainlinkOracle internal oracle;

    LendingMarket internal market;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockInterestRateModel internal irm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");

    RejectingCaller internal caller;

    bytes32 internal constant USDC_FEED_ID = keccak256("USDC/USD");
    bytes32 internal constant WETH_FEED_ID = keccak256("WETH/USD");

    uint256 internal constant FEE = 1 wei;
    uint256 internal constant EXACT_FEE = 4 * FEE;
    int32 internal constant EXPO = -8;
    uint256 internal constant FORCED = 1 ether;
    int64 internal constant CRASH_PRICE = 1_700e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockInterestRateModel(0, 0, 0.1e18);

        pyth = new MockPyth(365 days, FEE);
        usdcAnchor = new MockChainlinkFeed(8, 1e8, block.timestamp);
        wethAnchor = new MockChainlinkFeed(8, 2_000e8, block.timestamp);
        oracle = _deployOracle();

        LendingMarket.MarketConfig memory cfg =
            MarketBuilder.config(address(usdc), address(irm), address(oracle), owner, guardian);
        ILendingMarket.CollateralConfig[] memory collaterals = new ILendingMarket.CollateralConfig[](1);
        collaterals[0] = MarketBuilder.collateral(address(weth), 18, 1_000e18);
        market = new LendingMarket(cfg, collaterals);

        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(market), type(uint256).max);
        market.supply(address(usdc), 1_000_000e6);
        vm.stopPrank();

        // alice: 15,000 USDC debt against 10 WETH at $2,000, absorbable once WETH reaches $1,700.
        bytes[] memory update = _blob(2_000e8);
        weth.mint(alice, 10e18);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(market), type(uint256).max);
        market.supply(address(weth), 10e18);
        market.withdraw{value: EXACT_FEE}(address(usdc), 15_000e6, update);
        vm.stopPrank();

        caller = new RejectingCaller();
        vm.deal(address(caller), 1 ether);
        usdc.mint(address(caller), 100_000e6);
        weth.mint(address(caller), 10e18);
        caller.exec(address(usdc), 0, abi.encodeCall(usdc.approve, (address(market), type(uint256).max)));
        caller.exec(address(weth), 0, abi.encodeCall(weth.approve, (address(market), type(uint256).max)));

        vm.deal(liquidator, 1 ether);
        usdc.mint(liquidator, 100_000e6);
        vm.prank(liquidator);
        usdc.approve(address(market), type(uint256).max);
    }

    function _deployOracle() internal returns (PythChainlinkOracle) {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);

        PythChainlinkOracle.FeedConfig[] memory configs = new PythChainlinkOracle.FeedConfig[](2);
        configs[0] = PythChainlinkOracle.FeedConfig({
            pythFeedId: USDC_FEED_ID, chainlinkFeed: address(usdcAnchor), heartbeat: 86_400, set: false
        });
        configs[1] = PythChainlinkOracle.FeedConfig({
            pythFeedId: WETH_FEED_ID, chainlinkFeed: address(wethAnchor), heartbeat: 3_600, set: false
        });
        return new PythChainlinkOracle(address(pyth), 60, 200, 300, assets, configs);
    }

    function _blob(int64 wethPrice) internal view returns (bytes[] memory update) {
        update = new bytes[](2);
        update[0] = pyth.createPriceFeedUpdateData(USDC_FEED_ID, 1e8, 0, EXPO, 1e8, 0, uint64(block.timestamp));
        update[1] =
            pyth.createPriceFeedUpdateData(WETH_FEED_ID, wethPrice, 2e8, EXPO, wethPrice, 2e8, uint64(block.timestamp));
    }

    /// @dev Crashes WETH to $1,700 on the anchor one second later and returns the matching update.
    function _crash() internal returns (bytes[] memory) {
        vm.warp(block.timestamp + 1);
        wethAnchor.setAnswer(CRASH_PRICE, block.timestamp);
        return _blob(CRASH_PRICE);
    }

    function _forceBySelfdestruct() internal {
        new ForceSender{value: FORCED}(payable(address(market)));
        assertEq(address(market).balance, FORCED, "ETH forced in by selfdestruct");
    }

    function _forceByDeal() internal {
        vm.deal(address(market), FORCED);
    }

    /*//////////////////////////////////////////////////////////////
               A CONTRACT PAYING THE EXACT FEE IS NOT BLOCKED
    //////////////////////////////////////////////////////////////*/

    function _borrowAsCaller() internal {
        bytes[] memory update = _blob(2_000e8);
        caller.exec(address(market), 0, abi.encodeCall(market.supply, (address(weth), 10e18)));
        caller.exec(address(market), EXACT_FEE, abi.encodeCall(market.withdraw, (address(usdc), 10_000e6, update)));
        assertEq(market.borrowBalanceOf(address(caller)), 10_000e6, "contract borrowed");
    }

    function _absorbAsCaller() internal {
        bytes[] memory update = _crash();
        caller.exec(address(market), EXACT_FEE, abi.encodeCall(market.absorb, (alice, update)));
        assertEq(market.borrowBalanceOf(alice), 0, "contract absorbed");
    }

    /// @dev Absorbs alice from an EOA before any ETH is forced in, leaving 10 WETH of inventory.
    function _prepareInventory() internal returns (bytes[] memory update) {
        update = _crash();
        vm.prank(liquidator);
        market.absorb{value: EXACT_FEE}(alice, update);
    }

    function _buyAsCaller(bytes[] memory update) internal {
        caller.exec(
            address(market),
            EXACT_FEE,
            abi.encodeCall(market.buyCollateral, (address(weth), 0, 1_000e6, address(caller), update))
        );
        assertGt(weth.balanceOf(address(caller)), 0, "contract bought collateral");
    }

    function test_forcedBySelfdestruct_contractBorrowsWithExactFee() public {
        _forceBySelfdestruct();
        _borrowAsCaller();
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    function test_forcedByDeal_contractBorrowsWithExactFee() public {
        _forceByDeal();
        _borrowAsCaller();
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    function test_forcedBySelfdestruct_contractAbsorbsWithExactFee() public {
        _forceBySelfdestruct();
        _absorbAsCaller();
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    function test_forcedByDeal_contractAbsorbsWithExactFee() public {
        _forceByDeal();
        _absorbAsCaller();
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    function test_forcedBySelfdestruct_contractBuysCollateralWithExactFee() public {
        bytes[] memory update = _prepareInventory();
        _forceBySelfdestruct();
        _buyAsCaller(update);
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    function test_forcedByDeal_contractBuysCollateralWithExactFee() public {
        bytes[] memory update = _prepareInventory();
        _forceByDeal();
        _buyAsCaller(update);
        assertEq(address(market).balance, FORCED, "forced ETH stays in the market");
    }

    /*//////////////////////////////////////////////////////////////
                        REFUND IS THE CALLER'S OWN EXCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev An EOA sending 0.5 ETH gets back exactly 0.5 ETH minus the 4 wei fee: none of the forced
    ///      ETH, and none of its own excess kept.
    function test_excessIsRefundedExactlyToAnEoa() public {
        _forceByDeal();
        bytes[] memory update = _crash();
        uint256 ethBefore = liquidator.balance;
        int256 reservesBefore = market.getReserves();

        vm.prank(liquidator);
        market.absorb{value: 0.5 ether}(alice, update);

        assertEq(ethBefore - liquidator.balance, EXACT_FEE, "only the fee is spent");
        assertEq(address(market).balance, FORCED, "forced ETH neither refunded nor spent");
        assertEq(address(oracle).balance, 0, "oracle holds no ETH");
        assertEq(market.getReserves(), reservesBefore - int256(15_810e6), "forced ETH has no accounting effect");
    }

    /// @dev Forced ETH is not a fee budget: a caller sending nothing still owes the fee.
    function test_forcedEthDoesNotPayTheCallersFee() public {
        _forceByDeal();
        bytes[] memory update = _crash();

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientFee.selector, 0, 2 * FEE));
        market.absorb(alice, update);
    }

    /// @dev Overpaying from a contract that rejects ETH still reverts: the refund is the caller's own
    ///      excess, and the error carries exactly that amount, not the forced balance.
    function test_overpayingContractStillRevertsWithItsOwnExcess() public {
        _forceByDeal();
        bytes[] memory update = _crash();

        vm.expectRevert(
            abi.encodeWithSelector(ILendingMarket.RefundFailed.selector, address(caller), 0.5 ether - EXACT_FEE)
        );
        caller.exec(address(market), 0.5 ether, abi.encodeCall(market.absorb, (alice, update)));
    }
}
