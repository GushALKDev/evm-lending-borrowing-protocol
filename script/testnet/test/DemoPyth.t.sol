// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import {DemoPyth} from "../DemoPyth.sol";

/**
 * @title DemoPythTest
 * @notice The testnet Pyth stand-in: fee, last-write-wins storage, and the future publishTime guard.
 * @dev Run with FOUNDRY_PROFILE=testnet. Kept out of test/ so the protocol suite figures stay unchanged.
 */
contract DemoPythTest is Test {
    bytes32 internal constant ID = bytes32(uint256(1));

    DemoPyth internal pyth;

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new DemoPyth(1 wei);
    }

    function _update(int64 price, uint64 publishTime) internal view returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(ID, price, 1e5, -8, publishTime);
    }

    function test_update_storesPriceAndChargesOneFeePerEntry() public {
        bytes[] memory update = _update(2_000e8, uint64(block.timestamp));
        assertEq(pyth.getUpdateFee(update), 1 wei, "one wei per entry");

        pyth.updatePriceFeeds{value: 1 wei}(update);

        PythStructs.Price memory p = pyth.getPriceUnsafe(ID);
        assertEq(p.price, 2_000e8, "price");
        assertEq(p.conf, 1e5, "conf");
        assertEq(p.expo, -8, "expo");
        assertEq(p.publishTime, block.timestamp, "publishTime");
    }

    function test_update_revertsBelowTheFee() public {
        bytes[] memory update = _update(2_000e8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.InsufficientFee.selector, 0, 1));
        pyth.updatePriceFeeds{value: 0}(update);
    }

    /// @dev Regression guard for the griefing fix: with newer-wins, a price stamped one block ahead of the
    ///      app's would always be the one read. The last write must win, whatever its publishTime.
    function test_update_lastWriteWinsWhateverItsPublishTime() public {
        pyth.updatePriceFeeds{value: 1 wei}(_update(2_000e8, uint64(block.timestamp)));

        // An older publishTime still replaces it: the call that carries an update reads that update.
        pyth.updatePriceFeeds{value: 1 wei}(_update(1_000e8, uint64(block.timestamp - 1)));
        PythStructs.Price memory p = pyth.getPriceUnsafe(ID);
        assertEq(p.price, 1_000e8, "last write wins");
        assertEq(p.publishTime, block.timestamp - 1, "with its own publishTime");
    }

    /// @dev A future publishTime would let a stored price pass the oracle's staleness check for as long as
    ///      nobody writes over it.
    function test_update_rejectsAFuturePublishTime() public {
        uint64 future = uint64(block.timestamp + 1);
        bytes[] memory update = _update(2_000e8, future);
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.FuturePublishTime.selector, ID, future, block.timestamp));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    function test_getPriceUnsafe_revertsForAFeedNeverUpdated() public {
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceFeedNotFound.selector, ID));
        pyth.getPriceUnsafe(ID);
    }
}
