// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLHooks} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {ICLSubscriber} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";

/// @title Liquidity Per Second TrackerHook
/// @notice This hook is used to track the liquidity per second of subscribed liquidity within pools like in V3.
interface ILiquididityPerSecondTrackerHook is ICLSubscriber, ICLHooks {
    /// @return The seconds per **subscribed** liquidity cumulative for the pool
    /// @param key The key of the pool to check
    function getSecondsPerLiquidityCumulativeX128(
        PoolKey calldata key
    ) external view returns (uint256);

    /// @return The seconds per **subscribed** liquidity inside the tick range
    /// @param key The key of the pool to check
    /// @param tickLower The lower tick of the range
    function getSecondsPerLiquidityInsideX128(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256);
}
