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

import {PoolExtension} from "./libraries/PoolExtension.sol";
import {ILiquididityPerSecondTracker} from "./interfaces/ILiquididityPerSecondTracker.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract InRangeIncentiveHook is CLBaseHook, ILiquididityPerSecondTracker {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using CLPositionInfoLibrary for CLPositionInfo;
    using CLPoolGetters for CLPool.State;
    using CLPoolParametersHelper for bytes32;
    mapping(PoolId => PoolExtension.State) public pools;
    mapping(uint256 => PositionExtension.State) public positions;
    ICLPositionManager public immutable positionManager;
    IERC20 public incentiveToken;

    modifier onlyPositionManager() {
        require(
            msg.sender == address(positionManager),
            "InRangeIncentiveHook: only position manager"
        );
        _;
    }

    constructor(
        ICLPoolManager _poolManager,
        ICLPositionManager _positionManager,
        IERC20 _incentiveToken
    ) CLBaseHook(_poolManager) {
        positionManager = _positionManager;
        incentiveToken = _incentiveToken;
    }

    function _internalChangeRewardRate(
        PoolId poolId,
        uint72 rewardRate,
        uint32 blockNumber
    ) internal {
        pools[poolId].updateCumulative(blockNumber);
        pools[poolId].rewardsPerBlock = rewardRate;
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// Hooks Implementation ////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function getHooksRegistrationBitmap()
        external
        pure
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: false,
                    afterInitialize: true,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: false,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: false,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: false,
                    afterRemoveLiquidityReturnsDelta: false
                })
            );
    }
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override returns (bytes4) {
        pools[key.toId()].initialize(tick);
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _afterSwapTracker(key);
        return (this.afterSwap.selector, 0);
    }

    function _afterSwapTracker(PoolKey calldata key) internal {
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());
        PoolId id = key.toId();
        int tickBeforeSwap = pools[id].tick;
        if (tickBeforeSwap != tick) {
            pools[key.toId()].updateCumulative(uint32(block.number));
            pools[id].crossToActiveTick(key.parameters.getTickSpacing(), tick);
        }
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ISubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function _onSubscribeTracker(uint256 tokenId) internal {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        pools[poolKey.toId()].updateCumulative(uint32(block.number));
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
    function notifySubscribe(
        uint256 tokenId,
        bytes memory
    ) external override onlyPositionManager {
        _onSubscribeTracker(tokenId);
    }

    function _onUnubscribeTracker(uint256 tokenId) internal {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        pools[poolKey.toId()].updateCumulative(uint32(block.number));
        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: -int128(liquidity),
                tickSpacing: poolKey.parameters.getTickSpacing()
            })
        );

        positions[tokenId].updateRewards(
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );

        uint256 rewards = positions[tokenId].acruedReward;
        delete positions[tokenId];

        if (rewards > 0) {
            incentiveToken.transfer(
                IERC721(address(positionManager)).ownerOf(tokenId),
                rewards
            );
        }
    }

    /// @inheritdoc ICLSubscriber
    function notifyUnsubscribe(
        uint256 tokenId
    ) external override onlyPositionManager {
        _onUnubscribeTracker(tokenId);
    }

    function _onModifyLiquidityTracker(
        uint256 tokenId,
        int256 liquidityChange
    ) internal {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);

        // take liquididty before the change
        uint128 liquidity = uint128(
            int128(positionManager.getPositionLiquidity(tokenId)) -
                int128(liquidityChange)
        );

        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: int128(liquidityChange),
                tickSpacing: poolKey.parameters.getTickSpacing()
            })
        );

        positions[tokenId].updateRewards(
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );
    }

    /// @inheritdoc ICLSubscriber
    function notifyModifyLiquidity(
        uint256 tokenId,
        int256 liquidityChange,
        BalanceDelta
    ) external {
        _onModifyLiquidityTracker(tokenId, liquidityChange);
    }

    /// @inheritdoc ICLSubscriber
    function notifyTransfer(
        uint256 tokenId,
        address previousOwner,
        address newOwner
    ) external override {
        // do nothing
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

    function _isApprovedOrOwner(
        address spender,
        uint256 tokenId
    ) internal view returns (bool) {
        return
            spender == IERC721(address(positionManager)).ownerOf(tokenId) ||
            IERC721(address(positionManager)).getApproved(tokenId) == spender ||
            IERC721(address(positionManager)).isApprovedForAll(
                IERC721(address(positionManager)).ownerOf(tokenId),
                spender
            );
    }

    function callectRewards(
        uint256 tokenId,
        address to
    ) external returns (uint256 rewards) {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);

        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "SoloTracker: not approved or owner"
        );

        // take liquididty before the change
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        positions[tokenId].updateRewards(
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );
        rewards = positions[tokenId].collectRewards();

        if (rewards > 0) {
            incentiveToken.transfer(to, rewards);
        }
    }
}
