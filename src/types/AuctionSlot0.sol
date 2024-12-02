// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev AuctionSlot0 is a packed version of solidity structure.
 * Using the packaged version saves gas by not storing the structure fields in memory slots.
 *
 * Layout:
 * 16 bits minimum rent blocks| 8 bits transtion blocks | 8 overbid factor | 16 bits default swap fee | 24 bits maximum swap fee | 8 bits winner fee share | 8 strategy get fee gas limit | 160 bits strategy contract address
 *
 * Fields in the direction from the least significant bit:
 *
 * The strategy contract address (160bits)
 * is the address of the strategy contract that will be used to determine the swap fee.
 *
 * Strategy get fee gas limit (8bits)
 * is the log2 of the maximum amount of gas that can be used to call the strategy contract's getFee method.
 * for examples if the value is 18, the maximum amount of gas that can be used is 1 << 18.
 *
 * Winner fee share (8bits)
 * is the swapp fee part out of 255 that the winner collects. rest is distributed normally to the LPs.
 *
 * Maximum swap fee (24bits)
 * is the maximum swap fee that can be returned by the strategy contract - otherwise the default swap fee is used.
 *
 * Default swap fee (16bits)
 * is the default swap fee that will be used if the strategy contract reverts or returns a to high fee.
 *
 * Overbid factor (8bits)
 * is the factor that the winning bid has to be over the current bid to win the auction.
 * for example if the value is 2, the winning bid has to be at least 2/127 times higher then the current bid.
 *
 * Transition blocks (8bits)
 * the number of block at the end of the current rent period when any bid overbids.
 *
 * Minimum rent blocks (16bits)
 * the minimum number of blocks that a rent period can last.
 */
type AuctionSlot0 is bytes32;

using AuctionSlot0Library for AuctionSlot0 global;

/// @notice Library for getting and setting values in the AuctionSlot0 type
library AuctionSlot0Library {
    uint160 internal constant MASK_160_BITS =
        0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint16 internal constant MASK_16_BITS = 0xFFFF;
    uint8 internal constant MASK_8_BITS = 0xFF;

    uint8 internal constant STRATEGY_GAS_LIMIT_OFFSET = 160;
    uint8 internal constant WINNER_FEE_SHARE_OFFSET = 168;
    uint8 internal constant MAX_SWAP_FEE_OFFSET = 176;
    uint8 internal constant DEFAULT_SWAP_FEE_OFFSET = 200;
    uint8 internal constant OVERBID_FACTOR_OFFSET = 216;
    uint8 internal constant TRANSITION_BLOCKS_OFFSET = 224;
    uint8 internal constant MIN_RENT_BLOCKS_OFFSET = 232;

    // #### GETTERS ####
    function strategyAddress(
        AuctionSlot0 _packed
    ) internal pure returns (address _strategyAddress) {
        assembly ("memory-safe") {
            _strategyAddress := and(MASK_160_BITS, _packed)
        }
    }

    function strategyGasLimit(
        AuctionSlot0 _packed
    ) internal pure returns (uint256 _strategyGasLimit) {
        assembly ("memory-safe") {
            // 1 << strategyGasLimit
            _strategyGasLimit := shl(
                1,
                and(MASK_8_BITS, shr(STRATEGY_GAS_LIMIT_OFFSET, _packed))
            )
        }
    }

    function winnerFeeSharePart(
        AuctionSlot0 _packed
    ) internal pure returns (uint8 _winnerFeeShare) {
        assembly ("memory-safe") {
            _winnerFeeShare := and(
                MASK_8_BITS,
                shr(WINNER_FEE_SHARE_OFFSET, _packed)
            )
        }
    }

    function maxSwapFee(
        AuctionSlot0 _packed
    ) internal pure returns (uint24 _maxSwapFee) {
        assembly ("memory-safe") {
            _maxSwapFee := and(MASK_24_BITS, shr(MAX_SWAP_FEE_OFFSET, _packed))
        }
    }

    function defaultSwapFee(
        AuctionSlot0 _packed
    ) internal pure returns (uint24 _defaultSwapFee) {
        assembly ("memory-safe") {
            _defaultSwapFee := and(
                MASK_16_BITS,
                shr(DEFAULT_SWAP_FEE_OFFSET, _packed)
            )
        }
    }

    function overbidFactor(
        AuctionSlot0 _packed
    ) internal pure returns (uint8 _overbidFactor) {
        assembly ("memory-safe") {
            _overbidFactor := and(
                MASK_8_BITS,
                shr(OVERBID_FACTOR_OFFSET, _packed)
            )
        }
    }

    function transitionBlocks(
        AuctionSlot0 _packed
    ) internal pure returns (uint64 _transitionBlocks) {
        assembly ("memory-safe") {
            _transitionBlocks := and(
                MASK_16_BITS,
                shr(TRANSITION_BLOCKS_OFFSET, _packed)
            )
        }
    }

    function minRentBlocks(
        AuctionSlot0 _packed
    ) internal pure returns (uint64 _minRentBlocks) {
        assembly ("memory-safe") {
            _minRentBlocks := and(
                MASK_16_BITS,
                shr(MIN_RENT_BLOCKS_OFFSET, _packed)
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

    function setWinnerFeeShare(
        AuctionSlot0 _packed,
        uint8 _winnerFeeShare
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(WINNER_FEE_SHARE_OFFSET, MASK_8_BITS)), _packed),
                shl(WINNER_FEE_SHARE_OFFSET, and(MASK_8_BITS, _winnerFeeShare))
            )
        }
    }

    function setMaxSwapFee(
        AuctionSlot0 _packed,
        uint24 _maxSwapFee
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(MAX_SWAP_FEE_OFFSET, MASK_24_BITS)), _packed),
                shl(MAX_SWAP_FEE_OFFSET, and(MASK_24_BITS, _maxSwapFee))
            )
        }
    }

    function setDefaultSwapFee(
        AuctionSlot0 _packed,
        uint24 _defaultSwapFee
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(DEFAULT_SWAP_FEE_OFFSET, MASK_16_BITS)), _packed),
                shl(DEFAULT_SWAP_FEE_OFFSET, and(MASK_16_BITS, _defaultSwapFee))
            )
        }
    }

    function setOverbidFactor(
        AuctionSlot0 _packed,
        uint8 _overbidFactor
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(OVERBID_FACTOR_OFFSET, MASK_8_BITS)), _packed),
                shl(OVERBID_FACTOR_OFFSET, and(MASK_8_BITS, _overbidFactor))
            )
        }
    }

    function setTransitionBlocks(
        AuctionSlot0 _packed,
        uint16 _transitionBlocks
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(TRANSITION_BLOCKS_OFFSET, MASK_16_BITS)), _packed),
                shl(
                    TRANSITION_BLOCKS_OFFSET,
                    and(MASK_16_BITS, _transitionBlocks)
                )
            )
        }
    }

    function setMinRentBlocks(
        AuctionSlot0 _packed,
        uint16 _minRentBlocks
    ) internal pure returns (AuctionSlot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(MIN_RENT_BLOCKS_OFFSET, MASK_16_BITS)), _packed),
                shl(MIN_RENT_BLOCKS_OFFSET, and(MASK_16_BITS, _minRentBlocks))
            )
        }
    }
}
