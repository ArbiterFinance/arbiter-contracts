// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./libraries/PoolExtension.sol";
import {CLBaseHook} from "./pool-cl/CLBaseHook.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {ICLSubscriber} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";

import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {PoolExtension} from "./libraries/PoolExtension.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

abstract contract RewardTracker is IRewardTracker {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using CLPositionInfoLibrary for CLPositionInfo;
    using CLPoolGetters for CLPool.State;
    using CLPoolParametersHelper for bytes32;

    mapping(PoolId => PoolExtension.State) public pools;
    mapping(uint256 => PositionExtension.State) public positions;
    mapping(address => uint256) public accruedRewards;
    ICLPositionManager public immutable positionManager;

    modifier onlyPositionManager() {
        require(
            msg.sender == address(positionManager),
            "InRangeIncentiveHook: only position manager"
        );
        _;
    }

    constructor(ICLPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    /// @dev MUST be called before any rewards are distributed
    /// @dev for example call it in beforeInitialize or afterInititalize hook
    function _initialize(PoolId id, int24 tick) internal {
        pools[id].initialize(tick);
    }

    /// @dev MUST be called only after the pool has been initialized
    /// @dev for example call it in before/afterSwap , before/afterModifyLiquididty hooks
    function _distributeReward(PoolId id, uint128 rewards) internal {
        pools[id].distributeRewards(rewards);
    }

    /// @dev MUST be called in afterSwap whenever the actibe tick changes
    function _handleActiveTickChange(
        PoolId id,
        int24 newActiveTick,
        int24 tickSpacing
    ) internal {
        pools[id].crossToActiveTick(tickSpacing, newActiveTick);
    }

    /// @notice collects the accrued rewards for the caller
    /// @notice it's called at every Notification
    function _accrueRewards(
        uint256 tokenId,
        address owner,
        uint128 positionLiquidity,
        uint256 rewardsPerLiquidityCumulativeX128
    ) internal {
        accruedRewards[owner] += positions[tokenId].accumulateRewards(
            positionLiquidity,
            rewardsPerLiquidityCumulativeX128
        );
    }

    function _handleRemovePosition(
        uint256 tokenId,
        PoolKey memory key,
        CLPositionInfo positionInfo,
        uint128 liquidity
    ) internal {
        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[key.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );

        pools[key.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: -int128(liquidity),
                tickSpacing: key.parameters.getTickSpacing()
            })
        );

        delete positions[tokenId];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ICLSubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev is called before handling reward tracking operations on subscribe notification.
     * Can be overriden to add custom logic.
     *
     * @param key The PoolKey of a subscribing position.
     */
    function _beforeOnSubscribeTracker(PoolKey memory key) internal virtual;
    /**
     * @dev is called before handling reward tracking operations on unsubscribe notification.
     * Can be overriden to add custom logic.
     *
     * @param key The PoolKey of an unsubscribing position.
     */
    function _beforeOnUnubscribeTracker(PoolKey memory key) internal virtual;
    /**
     * @dev is called before handling reward tracking operations on transfer notification.
     * Can be overriden to add custom logic.
     *
     * @param key The PoolKey of a transferred position.
     */
    function _beforeOnTransferTracker(PoolKey memory key) internal virtual;
    /**
     * @dev is called before handling reward tracking operations on modify liquidity notification.
     * Can be overriden to add custom logic.
     *
     * @param key The PoolKey of a position with modified liquidity.
     */
    function _beforeOnModifyLiquidityTracker(
        PoolKey memory key
    ) internal virtual;

    /// @inheritdoc ICLSubscriber
    function notifySubscribe(
        uint256 tokenId,
        bytes memory
    ) external override onlyPositionManager {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnSubscribeTracker(poolKey);
        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: int128(liquidity),
                tickSpacing: poolKey.parameters.getTickSpacing()
            })
        );

        positions[tokenId].initialize(
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );
    }

    /// @inheritdoc ICLSubscriber
    function notifyUnsubscribe(
        uint256 tokenId
    ) external override onlyPositionManager {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnUnubscribeTracker(poolKey);

        _handleRemovePosition(
            tokenId,
            poolKey,
            positionInfo,
            uint128(liquidity)
        );
    }

    /// @inheritdoc ICLSubscriber
    function notifyModifyLiquidity(
        uint256 tokenId,
        int256 liquidityChange,
        BalanceDelta
    ) external {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);

        _beforeOnModifyLiquidityTracker(poolKey);

        // take liquididty before the change
        uint128 liquidity = uint128(
            int128(positionManager.getPositionLiquidity(tokenId)) -
                int128(liquidityChange)
        );

        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );

        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: int128(liquidityChange),
                tickSpacing: poolKey.parameters.getTickSpacing()
            })
        );
    }
    /// @inheritdoc ICLSubscriber
    function notifyTransfer(
        uint256 tokenId,
        address previousOwner,
        address newOwner
    ) external override {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);

        // take liquididty before the change
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnTransferTracker(poolKey);

        _accrueRewards(
            tokenId,
            previousOwner,
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );
    }
    function getRewardsPerLiquidityInsideX128(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (uint256) {
        return
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                tickLower,
                tickUpper
            );
    }

    function getRewardsPerLiquidityCumulativeX128(
        PoolKey calldata poolKey
    ) external view override returns (uint256) {
        return pools[poolKey.toId()].getRewardsPerLiquidityCumulativeX128();
    }
}
