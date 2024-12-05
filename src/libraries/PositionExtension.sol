// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {LiquidityMath} from "pancake-v4-core/src/pool-cl/libraries/LiquidityMath.sol";
import {CustomRevert} from "pancake-v4-core/src/libraries/CustomRevert.sol";

/// @title PositionExtension
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library PositionExtension {
    using CustomRevert for bytes4;

    /// @notice Cannot update a position with no liquidity
    error CannotUpdateEmptyPosition();

    // info stored for each user's position
    struct State {
        // the amount of liquidity owned by this position
        uint256 rewardsPerLiquidityLastX128;
    }

    /// @notice Returns the State struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => State) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (State storage position) {
        bytes32 positionKey = calculatePositionKey(
            owner,
            tickLower,
            tickUpper,
            salt
        );
        position = self[positionKey];
    }

    /// @notice A helper function to calculate the position key
    /// @param owner The address of the position owner
    /// @param tickLower the lower tick boundary of the position
    /// @param tickUpper the upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range, by the same owner. Passed in by the caller.
    function calculatePositionKey(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32 positionKey) {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x26), salt) // [0x26, 0x46)
            mstore(add(fmp, 0x06), tickUpper) // [0x23, 0x26)
            mstore(add(fmp, 0x03), tickLower) // [0x20, 0x23)
            mstore(fmp, owner) // [0x0c, 0x20)
            positionKey := keccak256(add(fmp, 0x0c), 0x3a) // len is 58 bytes

            // now clean the memory we used
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held salt
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held tickLower, tickUpper, salt
            mstore(fmp, 0) // fmp held owner
        }
    }

    /// @notice Calculates accumulated rewards and updates the user's position state
    function accumulateRewards(
        State storage self,
        uint128 positionLiquidity,
        uint256 rewardsPerLiquidityInsideX128
    ) internal returns (uint256 rewards) {
        unchecked {
            uint256 rewardsPerLiquididtyGrowthX128 = rewardsPerLiquidityInsideX128 -
                    self.rewardsPerLiquidityLastX128;

            rewards = FullMath.mulDiv(
                rewardsPerLiquididtyGrowthX128,
                positionLiquidity,
                FixedPoint128.Q128
            );

            self.rewardsPerLiquidityLastX128 = rewardsPerLiquidityInsideX128;
        }
    }

    function initialize(
        State storage self,
        uint256 rewardsPerLiquididtyInsideX128
    ) internal {
        self.rewardsPerLiquidityLastX128 = rewardsPerLiquididtyInsideX128;
    }
}
