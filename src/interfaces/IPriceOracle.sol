// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IPriceOracle
 * @author GushALKDev
 * @notice Price source contract for the market, returning a price and its confidence interval.
 * @dev Both functions revert rather than returning a degraded price: there is no silent fallback.
 *      The market picks the confidence band edge per context (capacity at price - conf, absorb
 *      eligibility at price + conf), so the oracle always reports the mid price and the half width.
 */
interface IPriceOracle {
    /**
     * @notice Pushes signed price update data on chain, then validates and returns the price.
     * @dev Payable: the caller funds the update fee via msg.value and any surplus is refunded.
     * @param asset Asset whose price is requested.
     * @param priceUpdate Signed price update payloads for the underlying pull oracle.
     * @return price18 Validated mid price at 1e18 scale, strictly positive.
     * @return conf18 Confidence interval half width at 1e18 scale.
     */
    function updateAndGetPrice(address asset, bytes[] calldata priceUpdate)
        external
        payable
        returns (uint256 price18, uint256 conf18);

    /**
     * @notice Reads the last stored price through the same validation pipeline.
     * @dev Reverts if the stored price is stale, too uncertain, or deviates from the anchor.
     * @param asset Asset whose price is requested.
     * @return price18 Validated mid price at 1e18 scale, strictly positive.
     * @return conf18 Confidence interval half width at 1e18 scale.
     */
    function getPrice(address asset) external view returns (uint256 price18, uint256 conf18);
}
