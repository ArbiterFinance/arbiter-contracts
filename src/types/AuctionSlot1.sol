// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev AuctionSlot1 is a packed version of solidity structure.
 * Using the packaged version saves gas by not storing the structure fields in memory slots.
 *
 * Layout:
 * 128 bits remaining rent | 32 bits last paid block | 24 bits last active tick | 1 bit should change strategy | 23 bits FREE SPACE | 8 bits strategy get fee gas limit | 24 bits maximum swap fee | 16 bits default swap fee
 *
 * Fields in the direction from the least significant bit:
 *
 * Remaining rent (128bits)
 * is the amount of rent that is still owed to the current rent period.
 *
 * Last paid block (32bits)
 * is the block number of the last block that the rent was paid.
 *
 * Last active tick (24bits)
 * is the active tick after the last swap.
 *
 * Should change strategy (1 bits)
 * is a flag that indicates if the strategy should be changed.
 *
 * FREE SPACE (23 bits)
 *
 * Strategy get fee gas limit (8bits)
 * is the log2 of the maximum amount of gas that can be used to call the strategy contract's getFee method.
 * for examples if the value is 18, the maximum amount of gas that can be used is 1 << 18.
 *
 * Maximum swap fee (24bits)
 * is the maximum swap fee that can be returned by the strategy contract - otherwise the default swap fee is used.
 *
 * Default swap fee (16bits)
 * is the default swap fee that will be used if the strategy contract reverts or returns a to high fee.
 */
type AuctionSlot1 is bytes32;

using AuctionSlot1Library for AuctionSlot1 global;

/// @notice Library for getting and setting values in the AuctionSlot1 type
library AuctionSlot1Library {
    uint128 internal constant MASK_128_BITS =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint32 internal constant MASK_32_BITS = 0xFFFFFFFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint16 internal constant MASK_16_BITS = 0xFFFF;
    uint8 internal constant MASK_8_BITS = 0xFF;
    uint8 internal constant MASK_1_BIT = 0x01;

    uint8 internal constant LAST_PAID_BLOCK_OFFSET = 128;
    uint8 internal constant LAST_ACTIVE_TICK_OFFSET = 160;
    uint8 internal constant SHOULD_CHANGE_STRATEGY_OFFSET = 184;
    uint8 internal constant STRATEGY_GAS_LIMIT_OFFSET = 208;
    uint8 internal constant MAX_SWAP_FEE_OFFSET = 216;
    uint8 internal constant DEFAULT_SWAP_FEE_OFFSET = 240;

    // #### GETTERS ####
    function remainingRent(
        AuctionSlot1 _packed
    ) internal pure returns (uint128 _remainingRent) {
        assembly ("memory-safe") {
            _remainingRent := and(MASK_128_BITS, _packed)
        }
    }

    function lastPaidBlock(
        AuctionSlot1 _packed
    ) internal pure returns (uint32 _lastPaidBlock) {
        assembly ("memory-safe") {
            _lastPaidBlock := and(
                MASK_32_BITS,
                shr(LAST_PAID_BLOCK_OFFSET, _packed)
            )
        }
    }

    function lastActiveTick(
        AuctionSlot1 _packed
    ) internal pure returns (int24 _lastActiveTick) {
        assembly ("memory-safe") {
            _lastActiveTick := signextend(
                2,
                shr(LAST_ACTIVE_TICK_OFFSET, _packed)
            )
        }
    }

    function shouldChangeStrategy(
        AuctionSlot1 _packed
    ) internal pure returns (bool _shouldChangeStrategy) {
        assembly ("memory-safe") {
            _shouldChangeStrategy := and(
                MASK_1_BIT,
                shr(SHOULD_CHANGE_STRATEGY_OFFSET, _packed)
            )
        }
    }

    function strategyGasLimit(
        AuctionSlot1 _packed
    ) internal pure returns (uint8 _strategyGasLimit) {
        assembly ("memory-safe") {
            _strategyGasLimit := and(
                MASK_8_BITS,
                shr(STRATEGY_GAS_LIMIT_OFFSET, _packed)
            )
        }
    }

    function maxSwapFee(
        AuctionSlot1 _packed
    ) internal pure returns (uint24 _maxSwapFee) {
        assembly ("memory-safe") {
            _maxSwapFee := and(MASK_24_BITS, shr(MAX_SWAP_FEE_OFFSET, _packed))
        }
    }

    function defaultSwapFee(
        AuctionSlot1 _packed
    ) internal pure returns (uint16 _defaultSwapFee) {
        assembly ("memory-safe") {
            _defaultSwapFee := and(
                MASK_16_BITS,
                shr(DEFAULT_SWAP_FEE_OFFSET, _packed)
            )
        }
    }

    // #### SETTERS ####
    function setRemainingRent(
        AuctionSlot1 _packed,
        uint128 _remainingRent
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(MASK_128_BITS), _packed),
                and(MASK_128_BITS, _remainingRent)
            )
        }
    }

    function setLastPaidBlock(
        AuctionSlot1 _packed,
        uint32 _lastPaidBlock
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(LAST_PAID_BLOCK_OFFSET, MASK_32_BITS)), _packed),
                shl(LAST_PAID_BLOCK_OFFSET, and(MASK_32_BITS, _lastPaidBlock))
            )
        }
    }

    function setLastActiveTick(
        AuctionSlot1 _packed,
        int24 _lastActiveTick
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(LAST_ACTIVE_TICK_OFFSET, MASK_24_BITS)), _packed),
                shl(LAST_ACTIVE_TICK_OFFSET, and(MASK_24_BITS, _lastActiveTick))
            )
        }
    }

    function setShouldChangeStrategy(
        AuctionSlot1 _packed,
        bool _shouldChangeStrategy
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(
                    not(shl(SHOULD_CHANGE_STRATEGY_OFFSET, MASK_1_BIT)),
                    _packed
                ),
                shl(
                    SHOULD_CHANGE_STRATEGY_OFFSET,
                    and(MASK_1_BIT, _shouldChangeStrategy)
                )
            )
        }
    }

    function setStrategyGasLimit(
        AuctionSlot1 _packed,
        uint8 _strategyGasLimit
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(STRATEGY_GAS_LIMIT_OFFSET, MASK_8_BITS)), _packed),
                shl(
                    STRATEGY_GAS_LIMIT_OFFSET,
                    and(MASK_8_BITS, _strategyGasLimit)
                )
            )
        }
    }

    function setMaxSwapFee(
        AuctionSlot1 _packed,
        uint24 _maxSwapFee
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(MAX_SWAP_FEE_OFFSET, MASK_24_BITS)), _packed),
                shl(MAX_SWAP_FEE_OFFSET, and(MASK_24_BITS, _maxSwapFee))
            )
        }
    }

    function setDefaultSwapFee(
        AuctionSlot1 _packed,
        uint16 _defaultSwapFee
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(DEFAULT_SWAP_FEE_OFFSET, MASK_16_BITS)), _packed),
                shl(DEFAULT_SWAP_FEE_OFFSET, and(MASK_16_BITS, _defaultSwapFee))
            )
        }
    }
}
