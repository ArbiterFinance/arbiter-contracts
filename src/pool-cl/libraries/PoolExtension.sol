// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "pancake-v4-core/src/libraries/TickBitmap.sol";
import {Position} from "pancake-v4-core/src/libraries/Position.sol";
import {UnsafeMath} from "pancake-v4-core/src/libraries/UnsafeMath.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "pancake-v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {SwapMath} from "pancake-v4-core/src/pool-cl/libraries/SwapMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Slot0} from "pancake-v4-core/src/pool-cl/types/Slot0.sol";
import {ProtocolFeeLibrary} from "pancake-v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityMath} from "pancake-v4-core/src/pool-cl/libraries/LiquidityMath.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "pancake-v4-core/src/libraries/CustomRevert.sol";

/// @notice a library that records staked/subscribed liquiduty and allows for the calculation of
///         the seconds per liquidity of a position
library PoolExtension {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    using PoolExtension for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 secondsPerLiquidityOutsideX128;
    }

    /// @dev The state of a pool extension
    struct State {
        int24 tick;
        uint256 secondsPerLiquidityCumulativeX128;
        uint128 liquidity;
        mapping(int24 tick => TickInfo) ticks;
        mapping(int16 wordPos => uint256) tickBitmap;
        mapping(bytes32 positionKey => Position.State) positions;
    }

    function _secondsPerLiquidityInsideX128(
        State storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256) {
        unchecked {
            if (tickLower >= tickUpper) return 0;

            if (self.tick < tickLower) {
                return
                    self.ticks[tickLower].secondsPerLiquidityOutsideX128 -
                    self.secondsPerLiquidityCumulativeX128;
            }
            if (self.tick >= tickUpper) {
                return
                    self.secondsPerLiquidityCumulativeX128 -
                    self.ticks[tickUpper].secondsPerLiquidityOutsideX128;
            }
            return
                self.secondsPerLiquidityCumulativeX128 -
                self.ticks[tickUpper].secondsPerLiquidityOutsideX128 -
                self.ticks[tickLower].secondsPerLiquidityOutsideX128;
        }
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
        if (params.tickLower < self.tick && self.tick < params.tickUpper) {
            self.liquidity = LiquidityMath.addDelta(
                self.liquidity,
                liquidityDelta
            );
        }
    }

    /// @notice Executes a swap against the state, and returns the amount deltas of the pool
    /// @dev PoolManager checks that the pool is initialized before calling
    function crossToActiveTick(
        State storage self,
        int24 tickSpacing,
        int24 activeTick
    ) internal {
        // initialize to the current tick
        int24 currentTick = self.tick;
        // initialize to the current liquidity
        int128 liquidityChange = 0;

        bool goingLeft = activeTick <= currentTick;

        while ((activeTick < currentTick) == goingLeft) {
            bool initialized;
            (currentTick, initialized) = self
                .tickBitmap
                .nextInitializedTickWithinOneWord(
                    currentTick,
                    tickSpacing,
                    goingLeft
                );

            int128 liquidityNet = PoolExtension.crossTick(
                self,
                currentTick,
                self.secondsPerLiquidityCumulativeX128
            );

            // if we're moving leftward, we interpret liquidityNet as the opposite sign
            // safe because liquidityNet cannot be type(int128).min
            unchecked {
                if (goingLeft) liquidityChange = -liquidityNet;
            }
            liquidityChange += liquidityNet;
        }

        self.tick = activeTick;
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
                info.secondsPerLiquidityOutsideX128 = self
                    .secondsPerLiquidityCumulativeX128;
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
    /// @param secondsPerLiquidityCumulativeX128 The seconds per active liquidity in total for the pool
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function crossTick(
        State storage self,
        int24 tick,
        uint256 secondsPerLiquidityCumulativeX128
    ) internal returns (int128 liquidityNet) {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            info.secondsPerLiquidityOutsideX128 =
                secondsPerLiquidityCumulativeX128 -
                info.secondsPerLiquidityOutsideX128;
            liquidityNet = info.liquidityNet;
        }
    }
}