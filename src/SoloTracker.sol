// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.26;

// import "./libraries/PoolExtension.sol";
// import {CLBaseHook} from "./pool-cl/CLBaseHook.sol";

// import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
// import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
// import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
// import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
// import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
// import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
// import {ICLSubscriber} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";

// import {PoolExtension} from "./libraries/PoolExtension.sol";
// import {ILiquididityPerSecondTrackerHook} from "./interfaces/ILiquididityPerSecondTrackerHook.sol";
// import {PositionExtension} from "./libraries/PositionExtension.sol";
// import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
// import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
// import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
// import {Tracker} from "./AbstractTracker.sol";

// contract SoloTracker is Tracker {
//     using PoolExtension for PoolExtension.State;
//     using PositionExtension for PositionExtension.State;
//     using PoolIdLibrary for PoolKey;
//     using CLPositionInfoLibrary for CLPositionInfo;
//     using CLPoolGetters for CLPool.State;
//     using CLPoolParametersHelper for bytes32;

//     mapping(PoolId => PoolExtension.State) public pools;
//     mapping(uint256 => PositionExtension.State) public positions;

//     ICLPositionManager public immutable positionManager;

//     modifier onlyPositionManager() {
//         require(
//             msg.sender == address(positionManager),
//             "PancakeSwapV4Staker::onlyPositionManager: not a cakev4 nft"
//         );
//         _;
//     }

//     constructor(
//         ICLPoolManager _poolManager,
//         ICLPositionManager _positionManager
//     ) CLBaseHook(_poolManager) {
//         positionManager = _positionManager;
//     }

//     function activeTick(PoolId poolId) public view returns (int24) {
//         return pools[poolId].tick;
//     }

//     function activeLiquidty(PoolId poolId) public view returns (uint128) {
//         return pools[poolId].liquidity;
//     }

//     //////////////////////////////////////////////////////////////////////////////////////
//     //////////////////////////////// Hooks Implementation ////////////////////////////////
//     //////////////////////////////////////////////////////////////////////////////////////

//     function getHooksRegistrationBitmap()
//         external
//         pure
//         override
//         returns (uint16)
//     {
//         return
//             _hooksRegistrationBitmapFrom(
//                 Permissions({
//                     beforeInitialize: false,
//                     afterInitialize: true,
//                     beforeAddLiquidity: false,
//                     afterAddLiquidity: false,
//                     beforeRemoveLiquidity: false,
//                     afterRemoveLiquidity: false,
//                     beforeSwap: false,
//                     afterSwap: true,
//                     beforeDonate: false,
//                     afterDonate: false,
//                     beforeSwapReturnsDelta: false,
//                     afterSwapReturnsDelta: false,
//                     afterAddLiquidityReturnsDelta: false,
//                     afterRemoveLiquidityReturnsDelta: false
//                 })
//             );
//     }
//     function afterInitialize(
//         address,
//         PoolKey calldata key,
//         uint160,
//         int24 tick
//     ) external override returns (bytes4) {
//         _afterInitializeTracker(key, tick);
//         return this.afterInitialize.selector;
//     }

//     function afterSwap(
//         address,
//         PoolKey calldata key,
//         ICLPoolManager.SwapParams calldata,
//         BalanceDelta,
//         bytes calldata
//     ) external override returns (bytes4, int128) {
//         _afterSwapTracker(key);
//         return (this.afterSwap.selector, 0);
//     }

//     function _afterInitializeTracker(
//         PoolKey calldata key,
//         int24 tick
//     ) internal {
//         pools[key.toId()].tick = tick;
//     }

//     function _afterSwapTracker(PoolKey calldata key) internal {
//         (, int24 tick, , ) = poolManager.getSlot0(key.toId());
//         pools[key.toId()].crossToActiveTick(
//             key.parameters.getTickSpacing(),
//             tick
//         );
//     }

//     //////////////////////////////////////////////////////////////////////////////////////
//     //////////////////////////////// ISubscriber Implementation //////////////////////////
//     //////////////////////////////////////////////////////////////////////////////////////

//     function _onSubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidity),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifySubscribe(
//         uint256 tokenId,
//         bytes memory
//     ) external onlyPositionManager {
//         _onSubscribeTracker(tokenId);
//     }

//     function _onUnubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: -int128(liquidity),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifyUnsubscribe(uint256 tokenId) external onlyPositionManager {
//         _onUnubscribeTracker(tokenId);
//     }

//     function _onModifyLiquidityTracker(
//         uint256 tokenId,
//         int256 liquidityChange
//     ) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidityChange),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifyModifyLiquidity(
//         uint256 tokenId,
//         int256 liquidityChange,
//         BalanceDelta
//     ) external {
//         _onModifyLiquidityTracker(tokenId, liquidityChange);
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifyTransfer(
//         uint256 tokenId,
//         address previousOwner,
//         address newOwner
//     ) external {
//         // do nothing
//     }
// }