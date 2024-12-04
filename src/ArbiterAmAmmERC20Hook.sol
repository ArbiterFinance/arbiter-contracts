// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.26;

// import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
// import {CLBaseHook} from "./pool-cl/CLBaseHook.sol";
// import {BeforeSwapDelta, toBeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
// import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
// import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
// import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
// import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
// import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
// import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
// import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";

// import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {IERC20Minimal} from "pancake-v4-core/src/interfaces/IERC20Minimal.sol";
// import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
// import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
// import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
// import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {console} from "forge-std/console.sol";

// import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
// import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";
// import {ILiquididityPerSecondTracker} from "./interfaces/ILiquididityPerSecondTracker.sol";
// import {PoolExtension} from "./libraries/PoolExtension.sol";
// import {PositionExtension} from "./libraries/PositionExtension.sol";
// import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
// import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
// import {ICLSubscriber} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";
// import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
// import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

// uint24 constant DEFAULT_SWAP_FEE = 300; // 0.03%
// uint24 constant MAX_FEE = 10000; // 1.0%

// /// @notice ArbiterAmAmmERC20Hook implements am-AMM auction and hook functionalities.
// /// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
// /// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
// /// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
// contract ArbiterAmAmmERC20Hook is
//     CLBaseHook,
//     IArbiterAmAmmHarbergerLease,
//     ILiquididityPerSecondTracker
// {
//     using PoolExtension for PoolExtension.State;
//     using PositionExtension for PositionExtension.State;
//     using CurrencyLibrary for Currency;
//     using LPFeeLibrary for uint24;
//     using PoolIdLibrary for PoolKey;
//     using SafeCast for int256;
//     using SafeCast for uint256;
//     using CLPositionInfoLibrary for CLPositionInfo;
//     using CLPoolGetters for CLPool.State;
//     using CLPoolParametersHelper for bytes32;

//     modifier onlyPositionManager() {
//         require(
//             msg.sender == address(positionManager),
//             "InRangeIncentiveHook: only position manager"
//         );
//         _;
//     }

//     /// @notice State used within hooks.
//     struct PoolHookState {
//         address strategy;
//         uint96 rentPerBlock;
//     }

//     struct RentData {
//         uint128 remainingRent;
//         uint48 lastPaidBlock;
//         uint32 rentEndBlock;
//         bool shouldChangeStrategy;
//         uint24 rentConfig; // could store additional data
//     }

//     /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
//     struct CallbackData {
//         address currency;
//         address sender;
//         uint256 depositAmount;
//         uint256 withdrawAmount;
//     }

//     mapping(PoolId => PoolHookState) public poolHookStates;
//     mapping(PoolId => RentData) public rentDatas;
//     mapping(PoolId => address) public winners;
//     mapping(PoolId => address) public winnerStrategies;
//     mapping(address => uint256) public deposits;

//     mapping(PoolId => PoolExtension.State) public pools;
//     mapping(uint256 => PositionExtension.State) public positions;
//     ICLPositionManager public immutable positionManager;

//     IERC20 public rentCurrency; // Rent currency

//     constructor(
//         ICLPoolManager _poolManager,
//         ICLPositionManager _positionManager,
//         uint48 _minimumRentTimeInBlocks,
//         uint64 _rentFactor,
//         uint48 _transitionBlocks,
//         uint256 _getSwapFeeGasLimit,
//         uint48 _winnerFeeShare,
//         bool _rentInTokenZero
//     ) CLBaseHook(_poolManager) {
//         console.log("[Constructor] Constructor start");
//         console.log(
//             "[Constructor] _minimumRentTimeInBlocks",
//             _minimumRentTimeInBlocks
//         );
//         console.log("[Constructor] _rentFactor", _rentFactor);
//         console.log("[Constructor] _transitionBlocks", _transitionBlocks);
//         console.log("[Constructor] _getSwapFeeGasLimit", _getSwapFeeGasLimit);
//         console.log("[Constructor] _rentInTokenZero", _rentInTokenZero);
//         console.log("[Constructor] _winnerFeeShare", _winnerFeeShare);
//         positionManager = _positionManager;
//         MINIMUM_RENT_TIME_IN_BLOCKS = _minimumRentTimeInBlocks;
//         RENT_FACTOR = _rentFactor;
//         TRANSTION_BLOCKS = _transitionBlocks;
//         GET_SWAP_FEE_GAS_LIMIT = _getSwapFeeGasLimit;
//         if (_winnerFeeShare > 100000) {
//             revert InvalidWinnerFeeShare();
//         }
//         WINNER_FEE_SHARE = _winnerFeeShare;
//         console.log("[Constructor] Constructor end");
//     }

//     ///////////////////////////////////////////////////////////////////////////////////
//     ////////////////////////////////////// HOOK ///////////////////////////////////////
//     ///////////////////////////////////////////////////////////////////////////////////

//     /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
//     function getHooksRegistrationBitmap()
//         external
//         pure
//         override
//         returns (uint16)
//     {
//         return
//             _hooksRegistrationBitmapFrom(
//                 Permissions({
//                     beforeInitialize: true,
//                     afterInitialize: true,
//                     beforeAddLiquidity: true,
//                     beforeRemoveLiquidity: false,
//                     afterAddLiquidity: false,
//                     afterRemoveLiquidity: false,
//                     beforeSwap: true,
//                     afterSwap: true,
//                     beforeDonate: false,
//                     afterDonate: false,
//                     beforeSwapReturnsDelta: true,
//                     afterSwapReturnsDelta: false,
//                     afterAddLiquidityReturnsDelta: false,
//                     afterRemoveLiquidityReturnsDelta: false
//                 })
//             );
//     }

//     /// @dev Reverts if dynamic fee flag is not set or if the pool is not initialized with dynamic fees.
//     function beforeInitialize(
//         address,
//         PoolKey calldata key,
//         uint160
//     ) external override poolManagerOnly returns (bytes4) {
//         console.log("[beforeInitialize] beforeInitialize start");
//         // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
//         if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();

//         poolHookStates[key.toId()] = PoolHookState({
//             strategy: address(0),
//             rentPerBlock: 0
//         });
//         console.log("[beforeInitialize] beforeInitialize end");
//         return this.beforeInitialize.selector;
//     }

//     function afterInitialize(
//         address,
//         PoolKey calldata key,
//         uint160,
//         int24 tick
//     ) external override returns (bytes4) {
//         pools[key.toId()].initialize(tick);
//         return this.afterInitialize.selector;
//     }

//     /// @notice Distributes rent to LPs before each liquidity change.
//     function beforeAddLiquidity(
//         address,
//         PoolKey calldata key,
//         ICLPoolManager.ModifyLiquidityParams calldata,
//         bytes calldata
//     ) external override poolManagerOnly returns (bytes4) {
//         console.log("[beforeAddLiquidity] beforeAddLiquidity start");
//         _updateAuctionState(key);
//         console.log("[beforeAddLiquidity] beforeAddLiquidity end");
//         return this.beforeAddLiquidity.selector;
//     }

//     /// @notice Distributes rent to LPs before each swap.
//     /// @notice Returns fee that will be paid to the hook and pays the fee to the strategist.
//     function beforeSwap(
//         address sender,
//         PoolKey calldata key,
//         ICLPoolManager.SwapParams calldata params,
//         bytes calldata hookData
//     )
//         external
//         override
//         poolManagerOnly
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         console.log("[beforeSwap] beforeSwap start");
//         address strategy = _updateAuctionState(key);

//         // If no strategy is set, the swap fee is just set to the default value
//         console.log("[beforeSwap] setting fee strategy");
//         if (strategy == address(0)) {
//             console.log("[beforeSwap] no strategy - setting default fee");
//             console.log("[beforeSwap] beforeSwap end");
//             return (
//                 this.beforeSwap.selector,
//                 toBeforeSwapDelta(0, 0),
//                 DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
//             );
//         }

//         // Call strategy contract to get swap fee.
//         uint256 fee = DEFAULT_SWAP_FEE;
//         try
//             IArbiterFeeProvider(strategy).getSwapFee(
//                 sender,
//                 key,
//                 params,
//                 hookData
//             )
//         returns (uint24 _fee) {
//             if (_fee > MAX_FEE) {
//                 fee = MAX_FEE;
//             } else {
//                 fee = _fee;
//             }
//         } catch {}
//         console.log("[beforeSwap] after strategy call");
//         console.log("[beforeSwap] fee", fee);

//         int256 totalFees = (params.amountSpecified * int256(fee)) / 1e6;
//         uint256 absTotalFees = totalFees < 0
//             ? uint256(-totalFees)
//             : uint256(totalFees);

//         // Calculate fee split
//         uint256 strategyFee = (absTotalFees * WINNER_FEE_SHARE) / 1e6;
//         uint256 lpFee = absTotalFees - strategyFee;

//         console.log("[beforeSwap] totalFees", totalFees);
//         console.log("[beforeSwap] strategyFee", strategyFee);
//         console.log("[beforeSwap] lpFee", lpFee);

//         // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
//         // If amountSpecified > 0, the swap is exact-out and it's the bought token.
//         bool exactOut = params.amountSpecified > 0;

//         Currency feeCurrency = exactOut == params.zeroForOne
//             ? key.currency0
//             : key.currency1;

//         console.log("[beforeSwap] feeCurrency", Currency.unwrap(feeCurrency));
//         console.log("[beforeSwap] exactOut", exactOut);
//         console.log(
//             "[beforeSwap] params.amountSpecified",
//             params.amountSpecified
//         );

//         // Send fees to strategy
//         vault.mint(strategy, feeCurrency, strategyFee);
//         if (exactOut) {
//             poolManager.donate(key, lpFee, 0, "");
//         } else {
//             poolManager.donate(key, 0, lpFee, "");
//         }

//         // Override LP fee to zero
//         console.log("[beforeSwap] beforeSwap end");
//         return (
//             this.beforeSwap.selector,
//             exactOut
//                 ? toBeforeSwapDelta(0, int128(totalFees))
//                 : toBeforeSwapDelta(0, -int128(totalFees)),
//             LPFeeLibrary.OVERRIDE_FEE_FLAG
//         );
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

//     ///////////////////////////////////////////////////////////////////////////////////
//     /////////////////////////// IArbiterAmAmmHarbergerLease ///////////////////////////
//     ///////////////////////////////////////////////////////////////////////////////////

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     uint48 public immutable override MINIMUM_RENT_TIME_IN_BLOCKS;

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     uint64 public immutable override RENT_FACTOR;

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     uint48 public immutable override TRANSTION_BLOCKS;

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     uint256 public immutable override GET_SWAP_FEE_GAS_LIMIT;

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     uint48 public immutable override WINNER_FEE_SHARE;

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function depositOf(
//         address asset,
//         address account
//     ) external view override returns (uint256) {
//         console.log("[depositOf] depositOf start");
//         uint256 depositAmount = deposits[account];
//         console.log("[depositOf] depositOf end");
//         return depositAmount;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function biddingCurrency(
//         PoolKey calldata key
//     ) external view override returns (address) {
//         console.log("[biddingCurrency] biddingCurrency start");
//         address currency = address(rentCurrency);
//         console.log("[biddingCurrency] biddingCurrency end");
//         return currency;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function activeStrategy(
//         PoolKey calldata key
//     ) external view override returns (address) {
//         console.log("[activeStrategy] activeStrategy start");
//         address strategy = poolHookStates[key.toId()].strategy;
//         console.log("[activeStrategy] activeStrategy end");
//         return strategy;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function winnerStrategy(
//         PoolKey calldata key
//     ) external view override returns (address) {
//         console.log("[winnerStrategy] winnerStrategy start");
//         address strategy = winnerStrategies[key.toId()];
//         console.log("[winnerStrategy] winnerStrategy end");
//         return strategy;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function winner(
//         PoolKey calldata key
//     ) external view override returns (address) {
//         console.log("[winner] winner start");
//         address winnerAddr = winners[key.toId()];
//         console.log("[winner] winner end");
//         return winnerAddr;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function rentPerBlock(
//         PoolKey calldata key
//     ) external view override returns (uint96) {
//         console.log("[rentPerBlock] rentPerBlock start");
//         uint96 rent = poolHookStates[key.toId()].rentPerBlock;
//         console.log("[rentPerBlock] rentPerBlock end");
//         return rent;
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function rentEndBlock(
//         PoolKey calldata key
//     ) external view override returns (uint48) {
//         console.log("[rentEndBlock] rentEndBlock start");
//         uint48 endBlock = rentDatas[key.toId()].rentEndBlock;
//         console.log("[rentEndBlock] rentEndBlock end");
//         return endBlock;
//     }

//     function deposit(address asset, uint256 amount) external override {
//         console.log("[deposit] deposit start");
//         console.log("[deposit] amount", amount);

//         rentCurrency.transferFrom(msg.sender, address(this), amount);

//         deposits[msg.sender] += amount;
//         console.log("[deposit] deposit end");
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function overbid(
//         PoolKey calldata key,
//         uint96 rentPerBlock,
//         uint32 rentEndBlock,
//         address strategy
//     ) external {
//         console.log("[overbid] overbid start");
//         console.log("[overbid] rentPerBlock", rentPerBlock);
//         console.log("[overbid] rentEndBlock", rentEndBlock);
//         console.log("[overbid] strategy", strategy);
//         uint48 minimumEndBlock = uint48(block.number) +
//             MINIMUM_RENT_TIME_IN_BLOCKS;
//         if (rentEndBlock < minimumEndBlock) {
//             revert RentTooShort();
//         }
//         (uint160 price, , , ) = poolManager.getSlot0(key.toId());
//         if (price == 0) {
//             revert PoolNotInitialized();
//         }

//         RentData memory rentData = rentDatas[key.toId()];
//         PoolHookState memory hookState = poolHookStates[key.toId()];
//         if (
//             rentData.rentEndBlock != 0 &&
//             block.number < rentData.rentEndBlock - TRANSTION_BLOCKS
//         ) {
//             uint96 minimumRentPerBlock = uint96(
//                 (hookState.rentPerBlock * RENT_FACTOR) / 1e6
//             );
//             if (rentPerBlock <= minimumRentPerBlock) {
//                 revert RentTooLow();
//             }
//         }

//         _updateAuctionState(key);

//         // refund the remaining rentPerBlock to the previous winner
//         deposits[winners[key.toId()]] += rentData.remainingRent;

//         // charge the new winner
//         uint128 requiredDeposit = rentPerBlock *
//             (rentEndBlock - uint48(block.number));
//         unchecked {
//             uint256 availableDeposit = deposits[msg.sender];
//             if (availableDeposit < requiredDeposit) {
//                 revert InsufficientDeposit();
//             }
//             deposits[msg.sender] = availableDeposit - requiredDeposit;
//         }

//         // set up new rent
//         rentData.remainingRent = requiredDeposit;
//         rentData.rentEndBlock = rentEndBlock;
//         rentData.shouldChangeStrategy = true;
//         hookState.rentPerBlock = rentPerBlock;
//         _internalChangeRewardRate(key.toId(), uint72(rentPerBlock));

//         rentDatas[key.toId()] = rentData;
//         poolHookStates[key.toId()] = hookState;
//         winners[key.toId()] = msg.sender;
//         winnerStrategies[key.toId()] = strategy;
//         console.log("[overbid] overbid end");
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function withdraw(address asset, uint256 amount) external override {
//         console.log("[withdraw] withdraw start");
//         console.log("[withdraw] asset", asset);
//         console.log("[withdraw] amount", amount);
//         uint256 depositAmount = deposits[msg.sender];
//         unchecked {
//             if (depositAmount < amount) {
//                 revert InsufficientDeposit();
//             }
//             deposits[msg.sender] = depositAmount - amount;
//         }
//         // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
//         rentCurrency.transfer(msg.sender, amount);
//         console.log("[withdraw] withdraw end");
//     }

//     /// @inheritdoc IArbiterAmAmmHarbergerLease
//     function changeStrategy(
//         PoolKey calldata key,
//         address strategy
//     ) external override {
//         console.log("[changeStrategy] changeStrategy start");
//         if (msg.sender != winners[key.toId()]) {
//             revert CallerNotWinner();
//         }
//         poolHookStates[key.toId()].strategy = strategy;
//         rentDatas[key.toId()].shouldChangeStrategy = true;
//         console.log("[changeStrategy] changeStrategy end");
//     }

//     ///////////////////////////////////////////////////////////////////////////////////
//     ///////////////////////////////////// Internal ////////////////////////////////////
//     ///////////////////////////////////////////////////////////////////////////////////

//     function _updateAuctionState(
//         PoolKey memory key
//     ) internal returns (address) {
//         console.log("[_updateAuctionState] _updateAuctionState start");
//         RentData memory rentData = rentDatas[key.toId()];
//         PoolHookState memory hookState = poolHookStates[key.toId()];
//         console.log("[_updateAuctionState] block number", block.number);
//         console.log(
//             "[_updateAuctionState] rentData.lastPaidBlock",
//             rentData.lastPaidBlock
//         );
//         console.log(
//             "[_updateAuctionState] rentData.rentEndBlock",
//             rentData.rentEndBlock
//         );
//         console.log(
//             "[_updateAuctionState] hookState.strategy",
//             hookState.strategy
//         );
//         console.log(
//             "[_updateAuctionState] hookState.rentPerBlock",
//             hookState.rentPerBlock
//         );
//         console.log(
//             "[_updateAuctionState] Remaining rent",
//             rentData.remainingRent
//         );

//         if (rentData.lastPaidBlock == block.number) {
//             console.log(
//                 "[_updateAuctionState] rentData.lastPaidBlock == block.number"
//             );
//             return hookState.strategy;
//         }

//         if (rentData.lastPaidBlock >= rentData.rentEndBlock) {
//             rentData.lastPaidBlock = uint48(block.number);
//             rentDatas[key.toId()] = rentData;
//             console.log(
//                 "[_updateAuctionState] rentData.lastPaidBlock >= rentData.rentEndBlock"
//             );
//             return hookState.strategy;
//         }

//         bool hookStateChanged = false;
//         // check if we need to change strategy
//         if (rentData.shouldChangeStrategy) {
//             console.log("[_updateAuctionState] rentData.shouldChangeStrategy");
//             hookState.strategy = winnerStrategies[key.toId()];
//             rentData.shouldChangeStrategy = false;
//             hookStateChanged = true;
//             console.log(
//                 "[_updateAuctionState] Strategy changed to",
//                 hookState.strategy
//             );
//         }

//         uint48 blocksElapsed;
//         if (rentData.rentEndBlock <= uint48(block.number)) {
//             blocksElapsed = rentData.rentEndBlock - rentData.lastPaidBlock;
//             winners[key.toId()] = address(0);
//             winnerStrategies[key.toId()] = address(0);
//             rentData.shouldChangeStrategy = true;
//             hookState.rentPerBlock = 0;
//             hookStateChanged = true;
//             console.log(
//                 "[_updateAuctionState] Rent period ended, resetting winner and strategy"
//             );
//         } else {
//             blocksElapsed = uint48(block.number) - rentData.lastPaidBlock;
//         }

//         rentData.lastPaidBlock = uint48(block.number);

//         uint128 rentAmount = hookState.rentPerBlock * blocksElapsed;

//         rentData.remainingRent -= rentAmount;

//         if (rentAmount > 0) {
//             _internalUpdateCumulativeTillNowOrRewardEnd(key.toId());
//         }

//         rentDatas[key.toId()] = rentData;
//         if (hookStateChanged) {
//             poolHookStates[key.toId()] = hookState;
//         }
//         console.log(
//             "[_updateAuctionState] Remaining rent after",
//             rentData.remainingRent
//         );

//         console.log("[_updateAuctionState] _updateAuctionState end");
//         return hookState.strategy;
//     }

//     ///////////////////////////////////////////////////////////////////////////////////
//     ///////////////////////////////////// Rewards tracking ////////////////////////////
//     ///////////////////////////////////////////////////////////////////////////////////

//     function _afterSwapTracker(PoolKey calldata key) internal {
//         (, int24 tick, , ) = poolManager.getSlot0(key.toId());
//         PoolId id = key.toId();
//         int tickBeforeSwap = pools[id].tick;
//         if (tickBeforeSwap != tick) {
//             _internalUpdateCumulativeTillNowOrRewardEnd(id);
//             pools[id].crossToActiveTick(key.parameters.getTickSpacing(), tick);
//         }
//     }

//     //////////////////////////////////////////////////////////////////////////////////////
//     //////////////////////////////// ISubscriber Implementation //////////////////////////
//     //////////////////////////////////////////////////////////////////////////////////////

//     function _onSubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         _internalUpdateCumulativeTillNowOrRewardEnd(poolKey.toId());
//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidity),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );

//         positions[tokenId].initialize(
//             pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
//                 positionInfo.tickLower(),
//                 positionInfo.tickUpper()
//             )
//         );
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifySubscribe(
//         uint256 tokenId,
//         bytes memory
//     ) external override onlyPositionManager {
//         _onSubscribeTracker(tokenId);
//     }

//     function _onUnubscribeTracker(uint256 tokenId) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         _internalUpdateCumulativeTillNowOrRewardEnd(poolKey.toId());
//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: -int128(liquidity),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );

//         positions[tokenId].updateRewards(
//             liquidity,
//             pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
//                 positionInfo.tickLower(),
//                 positionInfo.tickUpper()
//             )
//         );

//         uint256 rewards = positions[tokenId].accruedReward;
//         delete positions[tokenId];

//         if (rewards > 0) {
//             rentCurrency.transfer(
//                 IERC721(address(positionManager)).ownerOf(tokenId),
//                 rewards
//             );
//         }
//     }

//     /// @inheritdoc ICLSubscriber
//     function notifyUnsubscribe(
//         uint256 tokenId
//     ) external override onlyPositionManager {
//         _onUnubscribeTracker(tokenId);
//     }

//     function _onModifyLiquidityTracker(
//         uint256 tokenId,
//         int256 liquidityChange
//     ) internal {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);

//         // take liquididty before the change
//         uint128 liquidity = uint128(
//             int128(positionManager.getPositionLiquidity(tokenId)) -
//                 int128(liquidityChange)
//         );

//         pools[poolKey.toId()].modifyLiquidity(
//             PoolExtension.ModifyLiquidityParams({
//                 tickLower: positionInfo.tickLower(),
//                 tickUpper: positionInfo.tickUpper(),
//                 liquidityDelta: int128(liquidityChange),
//                 tickSpacing: poolKey.parameters.getTickSpacing()
//             })
//         );

//         positions[tokenId].updateRewards(
//             liquidity,
//             pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
//                 positionInfo.tickLower(),
//                 positionInfo.tickUpper()
//             )
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
//     ) external override {
//         // do nothing
//     }

//     function getRewardsPerLiquidityInsideX128(
//         PoolKey calldata poolKey,
//         int24 tickLower,
//         int24 tickUpper
//     ) external view override returns (uint256) {
//         return
//             pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
//                 tickLower,
//                 tickUpper
//             );
//     }

//     function getRewardsPerLiquidityCumulativeX128(
//         PoolKey calldata poolKey
//     ) external view override returns (uint256) {
//         return pools[poolKey.toId()].getRewardsPerLiquidityCumulativeX128();
//     }

//     function _isApprovedOrOwner(
//         address spender,
//         uint256 tokenId
//     ) internal view returns (bool) {
//         return
//             spender == IERC721(address(positionManager)).ownerOf(tokenId) ||
//             IERC721(address(positionManager)).getApproved(tokenId) == spender ||
//             IERC721(address(positionManager)).isApprovedForAll(
//                 IERC721(address(positionManager)).ownerOf(tokenId),
//                 spender
//             );
//     }

//     function callectRewards(
//         uint256 tokenId,
//         address to
//     ) external returns (uint256 rewards) {
//         (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
//             .getPoolAndPositionInfo(tokenId);

//         require(
//             _isApprovedOrOwner(msg.sender, tokenId),
//             "SoloTracker: not approved or owner"
//         );

//         // take liquididty before the change
//         uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

//         positions[tokenId].updateRewards(
//             liquidity,
//             pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
//                 positionInfo.tickLower(),
//                 positionInfo.tickUpper()
//             )
//         );
//         rewards = positions[tokenId].collectRewards();

//         if (rewards > 0) {
//             rentCurrency.transfer(to, rewards);
//         }
//     }

//     function _internalUpdateCumulativeTillNowOrRewardEnd(
//         PoolId poolId
//     ) internal {
//         RentData memory rentData = rentDatas[poolId];
//         if (rentData.rentEndBlock > block.number) {
//             pools[poolId].updateCumulative(uint32(block.number));
//         } else {
//             pools[poolId].updateCumulative(uint32(rentData.rentEndBlock));
//             pools[poolId].rewardsPerBlock = 0;
//         }
//     }

//     function _internalChangeRewardRate(
//         PoolId poolId,
//         uint72 rewardsPerBlock
//     ) internal {
//         _internalUpdateCumulativeTillNowOrRewardEnd(poolId);
//         pools[poolId].rewardsPerBlock = rewardsPerBlock;
//     }

//     function donate(uint256 amount) external {
//         rentCurrency.transferFrom(msg.sender, address(this), amount);
//         pools[poolId].donate(amount);
//     }
// }
