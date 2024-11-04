// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.24;

// import "./libraries/PoolExtension.sol";
// import {BaseHook} from "lib/v4-periphery/src/base/hooks/BaseHook.sol";

// import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
// import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
// import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
// import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
// import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
// import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
// import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

// import {ISubscriber} from "lib/v4-periphery/src/interfaces/ISubscriber.sol";

// import {PoolExtension} from "./libraries/PoolExtension.sol";
// // import {PositionExtension} from "./libraries/PositionExtension.sol";

// contract Tracker is BaseHook, ISubscriber {
//     using StateLibrary for IPoolManager;
//     using PoolExtension for PoolExtension.State;
//     using PoolIdLibrary for PoolKey;
//     using PositionInfoLibrary for PositionInfo;

//     mapping(PoolId => PoolExtension.State) public pools;
//     // mapping(uint256 => PositionExtension.State) public positions;

//     IPositionManager public immutable positionManager;

//     modifier onlyPositionManager() {
//         require(msg.sender == address(positionManager), "UniswapV4Staker::onlyPositionManager: not a univ4 nft");
//         _;
//     }

//     constructor(IPoolManager _poolManager, IPositionManager _positionManager) BaseHook(_poolManager) {
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

//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return
//             Hooks.Permissions({
//                 beforeInitialize: false,
//                 afterInitialize: true,
//                 beforeAddLiquidity: false,
//                 afterAddLiquidity: false,
//                 beforeRemoveLiquidity: false,
//                 afterRemoveLiquidity: false,
//                 beforeSwap: false,
//                 afterSwap: true,
//                 beforeDonate: false,
//                 afterDonate: false,
//                 beforeSwapReturnDelta: false,
//                 afterSwapReturnDelta: false,
//                 afterAddLiquidityReturnDelta: false,
//                 afterRemoveLiquidityReturnDelta: false
//             });
//     }

//     function afterInitialize(
//         address,
//         PoolKey calldata key,
//         uint160,
//         int24 tick,
//         bytes calldata
//     ) external override returns (bytes4) {
//         _afterInitializeTracker(key, tick);
//         return BaseHook.afterInitialize.selector;
//     }

//     function afterSwap(
//         address,
//         PoolKey calldata key,
//         IPoolManager.SwapParams calldata,
//         BalanceDelta,
//         bytes calldata
//     ) external override returns (bytes4, int128) {
//         _afterSwapTracker(key);
//         return (BaseHook.afterSwap.selector, 0);
//     }

//     function _afterInitializeTracker(PoolKey calldata key, int24 tick) internal {
//         pools[key.toId()].tick = tick;
//     }

//     function _afterSwapTracker(PoolKey calldata key) internal {
//         (, int24 tick, , ) = poolManager.getSlot0(key.toId());
//         pools[key.toId()].crossToActiveTick(key.tickSpacing, tick);
//     }

//     //////////////////////////////////////////////////////////////////////////////////////
//     //////////////////////////////// ISubscriber Implementation //////////////////////////
//     //////////////////////////////////////////////////////////////////////////////////////

//     function _onSubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidity),
//                 tickSpacing: poolKey.tickSpacing
//             })
//         );
//     }

//     /// @inheritdoc ISubscriber
//     function notifySubscribe(uint256 tokenId, bytes memory) external onlyPositionManager {
//         _onSubscribeTracker(tokenId);
//     }

//     function _onUnubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: -int128(liquidity),
//                 tickSpacing: poolKey.tickSpacing
//             })
//         );
//     }

//     /// @inheritdoc ISubscriber
//     function notifyUnsubscribe(uint256 tokenId) external onlyPositionManager {
//         _onUnubscribeTracker(tokenId);
//     }

//     function _onModifyLiquidityTracker(uint256 tokenId, int256 liquidityChange) internal {
//         (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidityChange),
//                 tickSpacing: poolKey.tickSpacing
//             })
//         );
//     }

//     /// @inheritdoc ISubscriber
//     function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta) external {
//         _onModifyLiquidityTracker(tokenId, liquidityChange);
//     }

//     /// @inheritdoc ISubscriber
//     function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external {
//         // do nothing
//     }
// }
