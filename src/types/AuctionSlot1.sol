// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev AuctionSlot1 is a packed version of solidity structure.
 * Using the packaged version saves gas by not storing the structure fields in memory slots.
 *
 * Layout:
 * 7 bits FREE SPACE | 96 bits rent per block | 1 bit should change strategy | 32 bits last paid block | 120 bits remaining rent
 *
 * Fields in the direction from the least significant bit:
 *
 * Remaining rent (120bits)
 * is the amount of rent that is still owed to the current rent period.
 *
 * Last paid block (32bits)
 * is the block number of the last block that the rent was paid.
 *
 * Should change strategy (1 bit)
 * is a flag that indicates if the strategy should be changed.
 *
 * Rent per block (96bits)
 * is the amount of rent that is paid per block.
 *
 * FREE SPACE (7bits)
 */
type AuctionSlot1 is bytes32;

using AuctionSlot1Library for AuctionSlot1 global;

/// @notice Library for getting and setting values in the AuctionSlot1 type
library AuctionSlot1Library {
    uint120 internal constant MASK_120_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint96 internal constant MASK_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;
    uint32 internal constant MASK_32_BITS = 0xFFFFFFFF;
    uint8 internal constant MASK_1_BIT = 0x01;

    uint8 internal constant LAST_PAID_BLOCK_OFFSET = 120;
    uint8 internal constant SHOULD_CHANGE_STRATEGY_OFFSET = 152;
    uint8 internal constant RENT_PER_BLOCK_OFFSET = 153;

    // #### GETTERS ####
    function remainingRent(
        AuctionSlot1 _packed
    ) internal pure returns (uint120 _remainingRent) {
        assembly ("memory-safe") {
            _remainingRent := and(MASK_120_BITS, _packed)
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

    function rentPerBlock(
        AuctionSlot1 _packed
    ) internal pure returns (uint96 _rentPerBlock) {
        assembly ("memory-safe") {
            _rentPerBlock := and(
                MASK_96_BITS,
                shr(RENT_PER_BLOCK_OFFSET, _packed)
            )
        }
    }

    // #### SETTERS ####
    function setRemainingRent(
        AuctionSlot1 _packed,
        uint120 _remainingRent
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(MASK_120_BITS), _packed),
                and(MASK_120_BITS, _remainingRent)
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
                    and(MASK_32_BITS, _shouldChangeStrategy)
                )
            )
        }
    }

    function setRentPerBlock(
        AuctionSlot1 _packed,
        uint96 _rentPerBlock
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(RENT_PER_BLOCK_OFFSET, MASK_96_BITS)), _packed),
                shl(RENT_PER_BLOCK_OFFSET, and(MASK_96_BITS, _rentPerBlock))
            )
        }
    }

    // #### UTILITY GETTERS ####
    function rentEndBlock(
        AuctionSlot1 _packed
    ) internal pure returns (uint64 _rentEndBlock) {
        uint96 _rentPerBlock = rentPerBlock(_packed);
        uint64 _lastPaidBlock = lastPaidBlock(_packed);
        if (_rentPerBlock == 0) {
            return _lastPaidBlock;
        } else
            return
                _lastPaidBlock +
                uint64((remainingRent(_packed) / _rentPerBlock) + 1);
    }
}
