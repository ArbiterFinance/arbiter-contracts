// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "infinity-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLSubscriber} from "infinity-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";

import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {PoolExtension} from "./libraries/PoolExtension.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";
import {CLPoolGetters} from "infinity-core/src/pool-cl/libraries/CLPoolGetters.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

abstract contract RewardTracker is IRewardTracker {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using CLPositionInfoLibrary for CLPositionInfo;
    using CLPoolGetters for CLPool.State;
    using CLPoolParametersHelper for bytes32;

    /// @dev The `account` is not Position Manager.
    error PositionManagerOnlyExecutor(address account);

    /// @notice Mapping of poolId to the tracked pool state
    /// @dev Key is PoolId, value is PoolExtension state struct
    mapping(PoolId => PoolExtension.State) public pools;

    /// @notice Mapping of tokenId to the tracked position state
    /// @dev Key is tokenId, value is PositionExtension state struct
    mapping(uint256 => PositionExtension.State) public positions;

    /// @notice Mapping of address to the accrued rewards
    /// @dev Key is address, value is accrued rewards
    mapping(address => uint256) public accruedRewards;

    ICLPositionManager public immutable positionManager;

    modifier onlyPositionManager() {
        require(
            msg.sender == address(positionManager),
            PositionManagerOnlyExecutor(msg.sender)
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
        pools[id].crossToTargetTick(tickSpacing, newActiveTick);
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
        address owner,
        PoolKey memory key,
        CLPositionInfo positionInfo,
        uint128 liquidity
    ) internal {
        _accrueRewards(
            tokenId,
            owner,
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
     * @dev is called before handling reward tracking operations on burn notification.
     * Can be overriden to add custom logic.
     *
     * @param key The PoolKey of a transferred position.
     */
    function _beforeOnBurnTracker(PoolKey memory key) internal virtual;
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
    /// @notice that after subscribing the position should be unsubscribed before transferring - otherwise the rewards will be lost in favor of the new owner
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
            IERC721(address(positionManager)).ownerOf(tokenId),
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
    function notifyBurn(
        uint256 tokenId,
        address owner,
        CLPositionInfo positionInfo,
        uint256 liquidity,
        BalanceDelta
    ) external override {
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(
            tokenId
        );

        _beforeOnBurnTracker(poolKey);

        _handleRemovePosition(
            tokenId,
            owner,
            poolKey,
            positionInfo,
            uint128(liquidity)
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
