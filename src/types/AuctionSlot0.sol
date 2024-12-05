// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AuctionSlot1Library, AuctionSlot1} from "./AuctionSlot1.sol";

/**
 * @dev AuctionSlot0 is a tightly packed data structure that holds multiple parameters
 * related to the auction's configuration and state.
 *
 * - [0..160): `strategy address` (160 bits) - The address of the current strategy contract.
 * - [160..184): `last active tick` (24 bits) - The tick at which the auction was last active.
 * - [184..185): `should change strategy` (8 bits) - A boolean flag indicating whether a new strategy should be applied.
 * - [185..208): `winner fee part` (16 bits) - The portion of the fee paid to the auction winner, expressed in basis points.
 * - [208..216): `strategy gas limit` (8 bits) - The maximum gas allocation for executing the strategy.
 * - [216..232): `default swap fee` (16 bits) - The default fee applied to swaps in basis points.
 * - [232..256): `auction fee` (24 bits) - The auction fee applied to the winning bid
 */
type AuctionSlot0 is bytes32;

using AuctionSlot0Library for AuctionSlot0 global;

/// @notice Library for getting and setting values in the AuctionSlot0 type
library AuctionSlot0Library {
    uint160 internal constant MASK_160_BITS =
        0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint8 internal constant MASK_1_BIT = 0x01;
    uint8 internal constant MASK_8_BITS = 0xFF;
    uint16 internal constant MASK_16_BITS = 0xFFFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint24 internal constant MASK_23_BITS = 0x7FFFFF;

    uint8 internal constant STRATEGY_ADDRESS_OFFSET = 0;
    uint8 internal constant LAST_ACTIVE_TICK_OFFSET = 160;
    uint8 internal constant SHOULD_CHANGE_STRATEGY_OFFSET = 184;
    uint8 internal constant WINNER_FEE_PART_OFFSET = 185;
    uint8 internal constant STRATEGY_GAS_LIMIT_OFFSET = 208;
    uint8 internal constant DEFAULT_SWAP_FEE_OFFSET = 216;
    uint8 internal constant AUCTION_FEE_OFFSET = 232;

    // #### GETTERS ####
    function strategyAddress(
        AuctionSlot0 _packed
    ) internal pure returns (address _strategyAddress) {
        assembly ("memory-safe") {
            _strategyAddress := and(MASK_160_BITS, _packed)
        }
    }

    function lastActiveTick(
        AuctionSlot0 _packed
    ) internal pure returns (int24 _lastActiveTick) {
        assembly ("memory-safe") {
            _lastActiveTick := signextend(
                2,
                shr(LAST_ACTIVE_TICK_OFFSET, _packed)
            )
        }
    }

    function shouldChangeStrategy(
        AuctionSlot0 _packed
    ) internal pure returns (bool _shouldChangeStrategy) {
        assembly ("memory-safe") {
            _shouldChangeStrategy := and(
                MASK_1_BIT,
                shr(SHOULD_CHANGE_STRATEGY_OFFSET, _packed)
            )
        }
    }

    function winnerFeeSharePart(
        AuctionSlot0 _packed
    ) internal pure returns (uint24 _winnerFeeSharePart) {
        assembly ("memory-safe") {
            _winnerFeeSharePart := and(
                MASK_23_BITS,
                shr(WINNER_FEE_PART_OFFSET, _packed)
            )
        }
    }

    function strategyGasLimit(
        AuctionSlot0 _packed
    ) internal pure returns (uint8 _strategyGasLimit) {
        assembly ("memory-safe") {
            _strategyGasLimit := and(
                MASK_8_BITS,
                shr(STRATEGY_GAS_LIMIT_OFFSET, _packed)
            )
        }
    }

    function defaultSwapFee(
        AuctionSlot0 _packed
    ) internal pure returns (uint16 _defaultSwapFee) {
        assembly ("memory-safe") {
            _defaultSwapFee := and(
                MASK_16_BITS,
                shr(DEFAULT_SWAP_FEE_OFFSET, _packed)
            )
        }
    }

    function auctionFee(
        AuctionSlot0 _packed
    ) internal pure returns (uint24 _auctionFee) {
        assembly ("memory-safe") {
            _auctionFee := and(MASK_24_BITS, shr(AUCTION_FEE_OFFSET, _packed))
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

    function setShouldChangeStrategy(
        AuctionSlot0 _packed,
        bool _shouldChangeStrategy
    ) internal pure returns (AuctionSlot0 _result) {
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

    function setLastActiveTick(
        AuctionSlot0 _packed,
        int24 _lastActiveTick
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(LAST_ACTIVE_TICK_OFFSET, MASK_24_BITS)), _packed),
                shl(LAST_ACTIVE_TICK_OFFSET, and(MASK_24_BITS, _lastActiveTick))
            )
        }
    }

    function setWinnerFeeSharePart(
        AuctionSlot0 _packed,
        uint24 _winnerFeeSharePart
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(WINNER_FEE_PART_OFFSET, MASK_23_BITS)), _packed),
                shl(
                    WINNER_FEE_PART_OFFSET,
                    and(MASK_23_BITS, _winnerFeeSharePart)
                )
            )
        }
    }

    function setStrategyGasLimit(
        AuctionSlot0 _packed,
        uint8 _strategyGasLimit
    ) internal pure returns (AuctionSlot0 _result) {
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

    function setDefaultSwapFee(
        AuctionSlot0 _packed,
        uint16 _defaultSwapFee
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(DEFAULT_SWAP_FEE_OFFSET, MASK_16_BITS)), _packed),
                shl(DEFAULT_SWAP_FEE_OFFSET, and(MASK_16_BITS, _defaultSwapFee))
            )
        }
    }

    function setAuctionFee(
        AuctionSlot0 _packed,
        uint24 _auctionFee
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(AUCTION_FEE_OFFSET, MASK_24_BITS)), _packed),
                shl(AUCTION_FEE_OFFSET, and(MASK_24_BITS, _auctionFee))
            )
        }
    }
}
