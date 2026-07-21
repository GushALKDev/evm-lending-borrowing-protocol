// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ILendingMarket} from "../../src/interfaces/ILendingMarket.sol";
import {LendingMarketHarness} from "./LendingMarketHarness.sol";

/**
 * @title MarketBuilder
 * @notice Helpers to assemble MarketConfig and CollateralConfig for tests, so each suite does not
 *         repeat the constructor bundle.
 */
library MarketBuilder {
    /// @notice A market config with sensible test defaults, overridable field by field afterwards.
    function config(address baseToken, address interestRateModel, address oracle, address owner, address guardian)
        internal
        pure
        returns (LendingMarket.MarketConfig memory)
    {
        return LendingMarket.MarketConfig({
            baseToken: baseToken,
            interestRateModel: interestRateModel,
            oracle: oracle,
            owner: owner,
            guardian: guardian,
            minBorrow: 100e6,
            targetReserves: 100_000e6
        });
    }

    /// @notice A single collateral config with the reference WETH-style factors.
    function collateral(address asset, uint8 decimals, uint128 supplyCap)
        internal
        pure
        returns (ILendingMarket.CollateralConfig memory)
    {
        return ILendingMarket.CollateralConfig({
            asset: asset,
            borrowCollateralFactor: 8000, // 80%
            liquidateCollateralFactor: 8500, // 85%
            liquidationFactor: 9300, // 93%
            storeFrontPriceFactor: 5000, // 50%
            supplyCap: supplyCap,
            decimals: decimals
        });
    }
}
