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
 * Rent per block (80bits)
 * is the amount of rent that is paid per block.
 *
 * Winner fee share (16bits)
 * is the swapp fee part out of  that the winner collects. rest is distributed normally to the LPs.
 *
 */
type AuctionSlot0 is bytes32;

using AuctionSlot0Library for AuctionSlot0 global;

/// @notice Library for getting and setting values in the AuctionSlot0 type
library AuctionSlot0Library {
    uint160 internal constant MASK_160_BITS =
        0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint80 internal constant MASK_80_BITS = 0xFFFFFFFFFFFFFFFFFFFF;
    uint16 internal constant MASK_16_BITS = 0xFFFF;

    uint8 internal constant RENT_PER_BLOCK_OFFSET = 160;
    uint8 internal constant WINNER_FEE_SHARE_OFFSET = 240;

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
    ) internal pure returns (uint80 _rentPerBlock) {
        assembly ("memory-safe") {
            _rentPerBlock := and(
                MASK_80_BITS,
                shr(RENT_PER_BLOCK_OFFSET, _packed)
            )
        }
    }

    function winnerFeeSharePart(
        AuctionSlot0 _packed
    ) internal pure returns (uint16 _winnerFeeShare) {
        assembly ("memory-safe") {
            _winnerFeeShare := and(
                MASK_16_BITS,
                shr(WINNER_FEE_SHARE_OFFSET, _packed)
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
        uint80 _rentPerBlock
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(MASK_80_BITS), _packed),
                shl(RENT_PER_BLOCK_OFFSET, _rentPerBlock)
            )
        }
    }

    function setWinnerFeeSharePart(
        AuctionSlot0 _packed,
        uint16 _winnerFeeShare
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(WINNER_FEE_SHARE_OFFSET, MASK_16_BITS)), _packed),
                shl(WINNER_FEE_SHARE_OFFSET, and(MASK_16_BITS, _winnerFeeShare))
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
