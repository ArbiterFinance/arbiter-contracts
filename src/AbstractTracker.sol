// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./libraries/PoolExtension.sol";

import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";

import {ICLSubscriber} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";

import {PoolExtension} from "./libraries/PoolExtension.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {ILiquididityPerSecondTrackerHook} from "./interfaces/ILiquididityPerSecondTrackerHook.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

abstract contract Tracker is ILiquididityPerSecondTrackerHook {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using CLPositionInfoLibrary for CLPositionInfo;
    using CLPoolGetters for CLPool.State;
    using CLPoolParametersHelper for bytes32;

    mapping(PoolId => PoolExtension.State) public pools;
    mapping(uint256 => PositionExtension.State) public positions;

    ICLPositionManager public immutable positionManager;

    modifier onlyPositionManager() {
        require(
            msg.sender == address(positionManager),
            "UniswapV4Staker::onlyPositionManager: not a univ4 nft"
        );
        _;
    }

    constructor(
        IPoolManager _poolManager,
        ICLPositionManager _positionManager
    ) {
        positionManager = _positionManager;
    }

    function activeTick(PoolId poolId) public view returns (int24) {
        return pools[poolId].tick;
    }

    function activeLiquidty(PoolId poolId) public view returns (uint128) {
        return pools[poolId].liquidity;
    }

    // function afterInitialize(
    //     address,
    //     PoolKey calldata key,
    //     uint160,
    //     int24 tick,
    //     bytes calldata
    // ) external override returns (bytes4) {
    //     _afterInitializeTracker(key, tick);
    //     return BaseHook.afterInitialize.selector;
    // }

    // function afterSwap(
    //     address,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata,
    //     BalanceDelta,
    //     bytes calldata
    // ) external override returns (bytes4, int128) {
    //     _afterSwapTracker(key);
    //     return (BaseHook.afterSwap.selector, 0);
    // }

    // function _afterInitializeTracker(PoolKey calldata key, int24 tick) internal {
    //     pools[key.toId()].tick = tick;
    // }

    // function _afterSwapTracker(PoolKey calldata key) internal {
    //     (, int24 tick, , ) = poolManager.getSlot0(key.toId());
    //     pools[key.toId()].crossToActiveTick(key.tickSpacing, tick);
    // }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ICLSubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function _onSubscribeTracker(uint256 tokenId) internal virtual {}

    /// @inheritdoc ICLSubscriber
    function notifySubscribe(
        uint256 tokenId,
        bytes memory data
    ) external virtual onlyPositionManager {
        _onSubscribeTracker(tokenId);
    }

    function _onUnubscribeTracker(uint256 tokenId) internal virtual {}

    /// @inheritdoc ICLSubscriber
    function notifyUnsubscribe(
        uint256 tokenId
    ) external virtual onlyPositionManager {
        _onUnubscribeTracker(tokenId);
    }

    function _onModifyLiquidityTracker(
        uint256 tokenId,
        int256 liquidityDelta
    ) internal virtual {}

    // /// @inheritdoc ICLSubscriber
    // function notifyModifyLiquidity(uint256 tokenId, int256 liquidityDelta, BalanceDelta feesAccrued) external {
    //     _onModifyLiquidityTracker(tokenId, liquidityDelta);
    // }

    /// @inheritdoc ICLSubscriber
    function notifyTransfer(
        uint256 tokenId,
        address previousOwner,
        address newOwner
    ) external virtual {
        // do nothing
    }
}
