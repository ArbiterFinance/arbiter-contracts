// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "infinity-core/src/pool-cl/libraries/TickBitmap.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityMath} from "infinity-core/src/pool-cl/libraries/LiquidityMath.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

/// @notice a library that records staked/subscribed liquiduty and allows for the calculation of
///         the rewards per liquidity of a position
library PoolExtension {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using PoolExtension for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;

    /// @notice info stored for each initialized individual tick
    struct TickInfo {
        /// @notice the total position liquidity that references this tick
        uint128 liquidityGross;
        /// @notice amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        /// @notice the rewards per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        /// @notice only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 rewardsPerLiquidityOutsideX128;
    }

    /// @notice Stores necessary info to track rewards per liquidity across ticks
    struct State {
        /// @notice rewards per liquidity of the pool
        uint256 rewardsPerLiquidityCumulativeX128;
        /// @notice the total liquidity of the pool participating in rewards
        uint128 liquidity;
        /// @notice the current tick
        int24 tick;
        /// @notice the tick info for each initialized tick
        /// @dev Key is the tick, value is the TickInfo struct
        mapping(int24 tick => TickInfo) ticks;
        /// @notice the tick bitmap used to efficiently find initialized ticks & flip
        /// @dev Key is the word position, value is the word
        mapping(int16 wordPos => uint256) tickBitmap;
    }

    function getRewardsPerLiquidityInsideX128(
        State storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256) {
        unchecked {
            if (tickLower >= tickUpper) return 0;

            if (self.tick < tickLower) {
                return
                    self.ticks[tickLower].rewardsPerLiquidityOutsideX128 -
                    self.ticks[tickUpper].rewardsPerLiquidityOutsideX128;
            }
            if (self.tick >= tickUpper) {
                return
                    self.ticks[tickUpper].rewardsPerLiquidityOutsideX128 -
                    self.ticks[tickLower].rewardsPerLiquidityOutsideX128;
            }
            return
                self.rewardsPerLiquidityCumulativeX128 -
                self.ticks[tickUpper].rewardsPerLiquidityOutsideX128 -
                self.ticks[tickLower].rewardsPerLiquidityOutsideX128;
        }
    }

    function getRewardsPerLiquidityCumulativeX128(
        State storage self
    ) internal view returns (uint256) {
        return self.rewardsPerLiquidityCumulativeX128;
    }

    function initialize(State storage self, int24 tick) internal {
        self.tick = tick;
    }

    struct ModifyLiquidityParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
        // the spacing between ticks
        int24 tickSpacing;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    function distributeRewards(
        State storage self,
        uint128 rewardsAmount
    ) internal {
        if (self.liquidity == 0) return;

        self.rewardsPerLiquidityCumulativeX128 +=
            (uint256(rewardsAmount) << 128) /
            self.liquidity;
    }

    /// @notice Effect changes to a position in a pool
    /// @dev PoolManager checks that the pool is initialized before calling
    /// @param params the position details and the change to the position's liquidity to effect
    function modifyLiquidity(
        State storage self,
        ModifyLiquidityParams memory params
    ) internal {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;

        ModifyLiquidityState memory state;

        // if we need to update the ticks, do it
        if (liquidityDelta != 0) {
            (state.flippedLower, state.liquidityGrossAfterLower) = updateTick(
                self,
                tickLower,
                liquidityDelta,
                false
            );
            (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(
                self,
                tickUpper,
                liquidityDelta,
                true
            );

            if (state.flippedLower) {
                self.tickBitmap.flipTick(tickLower, params.tickSpacing);
            }
            if (state.flippedUpper) {
                self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
            }
        }

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (state.flippedLower) {
                clearTick(self, tickLower);
            }
            if (state.flippedUpper) {
                clearTick(self, tickUpper);
            }
        }

        // update the active liquidity
        if (params.tickLower <= self.tick && self.tick < params.tickUpper) {
            self.liquidity = LiquidityMath.addDelta(
                self.liquidity,
                liquidityDelta
            );
        }
    }

    function isInitialized(
        State storage self,
        int24 tick,
        int24 tickSpacing
    ) internal view returns (bool) {
        unchecked {
            if (tick % tickSpacing != 0) return false;
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(
                tick / tickSpacing
            );
            return self.tickBitmap[wordPos] & (1 << bitPos) != 0;
        }
    }

    function crossToTargetTick(
        State storage self,
        int24 tickSpacing,
        int24 targetTick
    ) internal {
        // initialize to the current tick
        int24 currentTick = self.tick;
        // initialize to the current liquidity
        int128 liquidityChange = 0;

        bool lte = targetTick <= currentTick;

        if (lte) {
            while (targetTick < currentTick) {
                int24 nextTick;
                if (self.isInitialized(currentTick - 1, tickSpacing)) {
                    nextTick = currentTick - 1;
                } else {
                    (int24 _nextTick, ) = self
                        .tickBitmap
                        .nextInitializedTickWithinOneWord(
                            currentTick - 1,
                            tickSpacing,
                            lte
                        );
                    nextTick = _nextTick;
                }

                if (nextTick < targetTick) {
                    nextTick = targetTick;
                }

                // we cross through the currentTick to the nextTick (nextTick is not crossed)
                int128 liquidityNet = -PoolExtension.crossTick(
                    self,
                    currentTick,
                    self.rewardsPerLiquidityCumulativeX128
                );
                liquidityChange += liquidityNet;
                currentTick = nextTick;
            }
        } else {
            // going right
            while (currentTick < targetTick) {
                (int24 nextTick, ) = self
                    .tickBitmap
                    .nextInitializedTickWithinOneWord(
                        currentTick,
                        tickSpacing,
                        lte
                    );

                if (nextTick > targetTick) {
                    nextTick = targetTick;
                }

                // we cross the nextTick
                int128 liquidityNet = PoolExtension.crossTick(
                    self,
                    nextTick,
                    self.rewardsPerLiquidityCumulativeX128
                );
                liquidityChange += liquidityNet;
                currentTick = nextTick;
            }
        }

        self.tick = targetTick;

        self.liquidity = LiquidityMath.addDelta(
            self.liquidity,
            liquidityChange
        );
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    /// @return liquidityGrossAfter The total amount of liquidity for all positions that references the tick after the update
    function updateTick(
        State storage self,
        int24 tick,
        int128 liquidityDelta,
        bool upper
    ) internal returns (bool flipped, uint128 liquidityGrossAfter) {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= self.tick) {
                info.rewardsPerLiquidityOutsideX128 = self
                    .rewardsPerLiquidityCumulativeX128;
            }
        }

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        int128 liquidityNet = upper
            ? liquidityNetBefore - liquidityDelta
            : liquidityNetBefore + liquidityDelta;
        assembly ("memory-safe") {
            // liquidityGrossAfter and liquidityNet are packed in the first slot of `info`
            // So we can store them with a single sstore by packing them ourselves first
            sstore(
                info.slot,
                // bitwise OR to pack liquidityGrossAfter and liquidityNet
                or(
                    // Put liquidityGrossAfter in the lower bits, clearing out the upper bits
                    and(
                        liquidityGrossAfter,
                        0xffffffffffffffffffffffffffffffff
                    ),
                    // Shift liquidityNet to put it in the upper bits (no need for signextend since we're shifting left)
                    shl(128, liquidityNet)
                )
            )
        }
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clearTick(State storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The Pool state struct
    /// @param tick The destination tick of the transition
    /// @param rewardsPerLiquidityCumulativeX128 The rewards per active liquidity in total for the pool
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function crossTick(
        State storage self,
        int24 tick,
        uint256 rewardsPerLiquidityCumulativeX128
    ) internal returns (int128 liquidityNet) {
        unchecked {
            TickInfo storage info = self.ticks[tick];

            if (info.liquidityGross == 0) {
                return 0;
            }

            info.rewardsPerLiquidityOutsideX128 =
                rewardsPerLiquidityCumulativeX128 -
                info.rewardsPerLiquidityOutsideX128;
            liquidityNet = info.liquidityNet;
        }
    }
}
