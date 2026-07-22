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

    /**
     * @notice Maximum confidence half width over price the oracle accepts, in basis points.
     * @dev The market reads this at construction to enforce the absorb coverage condition (INV-13):
     *      a collateral must credit enough at liquidation to cover the worst-case high-edge valuation
     *      the oracle can pass. Immutable in every implementation.
     * @return Max confidence in basis points against 10_000.
     */
    // solhint-disable-next-line func-name-mixedcase
    function MAX_CONFIDENCE_BPS() external view returns (uint256);
}
