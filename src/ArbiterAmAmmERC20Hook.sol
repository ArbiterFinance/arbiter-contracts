// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {CLBaseHook} from "./pool-cl/CLBaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "pancake-v4-core/src/interfaces/IERC20Minimal.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {console} from "forge-std/console.sol";

import {AuctionSlot0, AuctionSlot0Library} from "./types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "./types/AuctionSlot1.sol";

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {CLPoolGetters} from "pancake-v4-core/src/pool-cl/libraries/CLPoolGetters.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {ArbiterAmAmmBaseHook} from "./ArbiterAmAmmBaseHook.sol";
import {RewardTracker} from "./RewardTracker.sol";

// TODO decide on the blockNumber storage size uint32 / uint48 / uint64

uint8 constant DEFAULT_WINNER_FEE_SHARE = 6; // 6/127 ~= 4.72%
uint8 constant DEFAULT_GET_SWAP_FEE_LOG = 13; // 2^13 = 8192
uint24 constant DEFAULT_MAX_POOL_SWAP_FEE = 10000; // 1.0%
uint16 constant DEFAULT_DEFAULT_POOL_SWAP_FEE = 300; // 0.03%
uint8 constant DEFAULT_OVERBID_FACTOR = 4; // 4/127 ~= 3.15%
uint8 constant DEFAULT_TRANSITION_BLOCKS = 20;
uint16 constant DEFAULT_MINIMUM_RENT_BLOCKS = 300;

uint24 constant DEFAULT_FEE = 400; // 0.04%

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmERC20Hook is ArbiterAmAmmBaseHook, RewardTracker {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using CLPoolGetters for CLPool.State;
    using CLPoolParametersHelper for bytes32;

    Currency immutable rentCurrency;

    constructor(
        ICLPoolManager poolManager_,
        ICLPositionManager positionManager_,
        address rentCurrency_,
        address initOwner_,
        uint32 transitionBlocks_,
        uint32 minRentBlocks_,
        uint32 overbidFactor_
    )
        ArbiterAmAmmBaseHook(
            poolManager_,
            initOwner_,
            transitionBlocks_,
            minRentBlocks_,
            overbidFactor_
        )
        RewardTracker(positionManager_)
    {
        rentCurrency = Currency.wrap(rentCurrency_);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not initialized with dynamic fees.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override poolManagerOnly returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();
        PoolId poolId = key.toId();

        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        poolSlot0[poolId] = AuctionSlot0
            .wrap(bytes32(0))
            .setWinnerFeeSharePart(DEFAULT_WINNER_FEE_SHARE)
            .setStrategyGasLimit(DEFAULT_GET_SWAP_FEE_LOG)
            .setLastActiveTick(tick);

        _initialize(poolId, tick);

        return this.beforeInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        AuctionSlot0 slot0 = poolSlot0[poolId];
        if (tick != slot0.lastActiveTick()) {
            _updateAuctionStateAndPayRent(key);
            _changeActiveTick(poolId, tick, key.parameters.getTickSpacing());
        }

        return (this.afterSwap.selector, 0);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////// ArbiterAmAmmBase Internal Overrides /////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _getPoolRentCurrency(
        PoolKey memory
    ) internal view override returns (Currency) {
        return rentCurrency;
    }

    function _distributeRent(
        PoolKey memory key,
        uint128 rentAmount
    ) internal override {
        _distributeReward(key.toId(), rentAmount);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////////// RewardTracker Overrides //////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _beforeOnSubscribeTracker(PoolKey memory key) internal override {
        _updateAuctionStateAndPayRent(key);
    }

    function _beforeOnUnubscribeTracker(PoolKey memory key) internal override {
        _updateAuctionStateAndPayRent(key);
    }

    function _beforeOnModifyLiquidityTracker(
        PoolKey memory key
    ) internal override {
        _updateAuctionStateAndPayRent(key);
    }

    function _beforeOnNotifyTransferTracker(
        PoolKey memory key
    ) internal override {
        _updateAuctionStateAndPayRent(key);
    }

    function collectRewards(address to) external returns (uint256 rewards) {
        rewards = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;

        vault.lock(
            abi.encode(
                CallbackData(Currency.unwrap(rentCurrency), to, 0, rewards)
            )
        );
    }
}
