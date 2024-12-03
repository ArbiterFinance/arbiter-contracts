// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AuctionSlot1Library, AuctionSlot1} from "./AuctionSlot1.sol";

/**
 * @dev AuctionSlot0 is a packed version of solidity structure.
 * Using the packaged version saves gas by not storing the structure fields in memory slots.
 *
 * Layout:
 * 96 bits rent per block | 160 bits strategy contract address
 *
 * Fields in the direction from the least significant bit:
 *
 * The strategy contract address (160bits)
 * is the address of the strategy contract that will be used to determine the swap fee.
 *
 * Rent per block (96bits)
 * is the amount of rent that is paid per block.
 *
 */
type AuctionSlot0 is bytes32;

using AuctionSlot0Library for AuctionSlot0 global;

/// @notice Library for getting and setting values in the AuctionSlot0 type
library AuctionSlot0Library {
    uint160 internal constant MASK_160_BITS =
        0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint96 internal constant MASK_96_BITS = 0xFFFFFFFFFFFFFFFF;

    uint8 internal constant RENT_PER_BLOCK_OFFSET = 160;

    // #### GETTERS ####
    function strategyAddress(
        AuctionSlot0 _packed
    ) internal pure returns (address _strategyAddress) {
        assembly ("memory-safe") {
            _strategyAddress := and(MASK_160_BITS, _packed)
        }
    }

    function rentPerBlock(
        AuctionSlot0 _packed
    ) internal pure returns (uint96 _rentPerBlock) {
        assembly ("memory-safe") {
            _rentPerBlock := and(
                MASK_96_BITS,
                shr(RENT_PER_BLOCK_OFFSET, _packed)
            )
        }
    }

    // #### SETTERS ####
    function setStrategyAddress(
        AuctionSlot0 _packed,
        address _strategyAddress
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(MASK_160_BITS), _packed),
                and(MASK_160_BITS, _strategyAddress)
            )
        }
    }

    function setRentPerBlock(
        AuctionSlot0 _packed,
        uint96 _rentPerBlock
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(MASK_96_BITS), _packed),
                shl(RENT_PER_BLOCK_OFFSET, _rentPerBlock)
            )
        }
    }

    // #### UTILITIES ####
    function rentEndBlock(
        AuctionSlot0 _packed,
        AuctionSlot1 _packed1
    ) internal pure returns (uint32) {
        uint96 _rentPerBlock = _packed.rentPerBlock();
        if (_rentPerBlock == 0) {
            return _packed1.lastPaidBlock();
        }
        return
            _packed1.lastPaidBlock() +
            uint32(_packed1.remainingRent() / _rentPerBlock);
    }
}
