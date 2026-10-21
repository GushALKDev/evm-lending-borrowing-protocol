// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title DemoPyth
 * @author GushALKDev
 * @notice Testnet-only stand-in for the Pyth pull oracle. Never deploy it on a network with real value.
 * @dev Pyth's Hermes service requires a paid API key since the Pyth Core upgrade (August 2026), so the
 *      public testnet demo cannot fetch signed updates. This contract accepts unsigned updates in
 *      MockPyth's encoding (one abi-encoded PythStructs.PriceFeed per entry), and the demo app fills
 *      them with the Chainlink answer of the same chain right before each price-dependent call.
 *
 *      It implements only the three IPyth functions PythChainlinkOracle calls: getUpdateFee,
 *      updatePriceFeeds and getPriceUnsafe. Two differences from Pyth and its MockPyth:
 *      - the last write wins, whatever its publishTime. Pyth keeps the newest publishTime, which with
 *        unsigned updates would let anyone push a price stamped with the current block, one block newer
 *        than the app can stamp its own, and make every call read theirs. Here the update a call carries
 *        is the price that same call reads: nobody can slip a write in between.
 *      - an update with a publishTime in the future reverts, so a stored price can never dodge the
 *        oracle's staleness check.
 *      Nothing else is verified. Anyone can store any price. The oracle's Chainlink deviation anchor
 *      is what bounds it: a price more than MAX_DEVIATION_BPS away from the anchor makes every
 *      price-dependent call revert, and the next call that carries its own update replaces it.
 */
contract DemoPyth {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Same shape as IPythEvents.PriceFeedUpdate, emitted when a stored price is replaced.
    event PriceFeedUpdate(bytes32 indexed id, uint64 publishTime, int64 price, uint64 conf);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientFee(uint256 provided, uint256 required);
    error FuturePublishTime(bytes32 id, uint256 publishTime, uint256 blockTimestamp);
    error PriceFeedNotFound(bytes32 id);

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee charged per update entry, in wei.
    uint256 public immutable SINGLE_UPDATE_FEE;

    /// @notice Latest stored price per feed id.
    mapping(bytes32 id => PythStructs.Price price) internal prices;

    /**
     * @param singleUpdateFee Fee per update entry, in wei. The demo uses 1 wei, like the repo's tests.
     */
    constructor(uint256 singleUpdateFee) {
        SINGLE_UPDATE_FEE = singleUpdateFee;
    }

    /*//////////////////////////////////////////////////////////////
                                 PYTH API
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee for a batch of updates: one SINGLE_UPDATE_FEE per entry, as in MockPyth.
    function getUpdateFee(bytes[] calldata updateData) public view returns (uint256) {
        return SINGLE_UPDATE_FEE * updateData.length;
    }

    /**
     * @notice Stores every price in the update, replacing whatever was stored (see the contract notes).
     * @dev Keeps the whole msg.value, like Pyth: PythChainlinkOracle sends exactly the fee.
     * @param updateData One abi-encoded PythStructs.PriceFeed per entry.
     */
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        uint256 fee = getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        for (uint256 i = 0; i < updateData.length; i++) {
            PythStructs.PriceFeed memory feed = abi.decode(updateData[i], (PythStructs.PriceFeed));
            if (feed.price.publishTime > block.timestamp) {
                revert FuturePublishTime(feed.id, feed.price.publishTime, block.timestamp);
            }
            prices[feed.id] = feed.price;
            emit PriceFeedUpdate(feed.id, uint64(feed.price.publishTime), feed.price.price, feed.price.conf);
        }
    }

    /**
     * @notice Latest stored price, with no freshness check: the caller applies its own.
     * @param id Feed id.
     * @return The stored price. Reverts if the feed has never been updated, like Pyth.
     */
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory price = prices[id];
        if (price.publishTime == 0) revert PriceFeedNotFound(id);
        return price;
    }

    /**
     * @notice Encodes one update entry, for scripts and tests. The app encodes the same struct itself.
     * @param id Feed id.
     * @param price Price mantissa.
     * @param conf Confidence half width, same exponent as the price.
     * @param expo Exponent shared by price and conf.
     * @param publishTime Unix timestamp of the price, at most the current block timestamp.
     * @return One update entry for updatePriceFeeds.
     */
    function createPriceFeedUpdateData(bytes32 id, int64 price, uint64 conf, int32 expo, uint64 publishTime)
        external
        pure
        returns (bytes memory)
    {
        PythStructs.PriceFeed memory feed;
        feed.id = id;
        feed.price = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        feed.emaPrice = feed.price;
        return abi.encode(feed);
    }
}
