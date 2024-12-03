// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev AuctionSlot1 is a tightly packed data structure that holds multiple parameters
 * related to the auction's financial state and configuration.
 *
 * - [0..128): `remaining rent` (128 bits) - The amount of rent that is still owed for the current rent period.
 * - [128..160): `last paid block` (32 bits) - The block number of the last block when rent was paid.
 * - [160..256): `rent per block` (96 bits) - The amount of rent paid per block.
 */

type AuctionSlot1 is bytes32;
using AuctionSlot1Library for AuctionSlot1 global;

/// @notice Library for getting and setting values in the AuctionSlot1 type
library AuctionSlot1Library {
    uint128 internal constant MASK_128_BITS =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint96 internal constant MASK_96_BITS = 0xFFFFFFFFFFFFFFFFFFFF;
    uint32 internal constant MASK_32_BITS = 0xFFFFFFFF;

    uint8 internal constant LAST_PAID_BLOCK_OFFSET = 128;
    uint8 internal constant RENT_PER_BLOCK = 160;

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

    function rentPerBlock(
        AuctionSlot1 _packed
    ) internal pure returns (uint96 _rentPerBlock) {
        assembly ("memory-safe") {
            _rentPerBlock := and(MASK_96_BITS, shr(RENT_PER_BLOCK, _packed))
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

    function setRentPerBlock(
        AuctionSlot1 _packed,
        uint96 _rentPerBlock
    ) internal pure returns (AuctionSlot1 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(RENT_PER_BLOCK, MASK_96_BITS)), _packed),
                shl(RENT_PER_BLOCK, and(MASK_96_BITS, _rentPerBlock))
            )
        }
    }

    // #### UTILITY ####
    function rentEndBlock(AuctionSlot1 _packed) internal pure returns (uint32) {
        uint128 _remainingRent = remainingRent(_packed);
        uint32 _lastPaidBlock = lastPaidBlock(_packed);

        if (_remainingRent == 0) {
            return _lastPaidBlock;
        }
        unchecked {
            return
                _lastPaidBlock + uint32(_remainingRent / rentPerBlock(_packed));
        }
    }
}
