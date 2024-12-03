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
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {console} from "forge-std/console.sol";

import {AuctionSlot0, AuctionSlot0Library} from "./types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "./types/AuctionSlot1.sol";

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {ArbiterAmAmmBaseHook} from "./ArbiterAmAmmBaseHook.sol";

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
contract ArbiterAmAmmSimpleHook is ArbiterAmAmmBaseHook {
    bool immutable RENT_IN_TOKEN_ZERO;

    using LPFeeLibrary for uint24;

    constructor(
        ICLPoolManager poolManager_,
        bool rentInTokenZero_,
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
    {
        RENT_IN_TOKEN_ZERO = rentInTokenZero_;
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHooksRegistrationBitmap()
        external
        pure
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: true,
                    afterInitialize: false,
                    beforeAddLiquidity: true,
                    beforeRemoveLiquidity: false,
                    afterAddLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: true,
                    afterSwap: false,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: true,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: false,
                    afterRemoveLiquidityReturnsDelta: false
                })
            );
    }

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not initialized with dynamic fees.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override poolManagerOnly returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();
        PoolId poolId = key.toId();

        poolSlot1[poolId] = AuctionSlot1.wrap(bytes32(0)).setStrategyGasLimit(
            DEFAULT_GET_SWAP_FEE_LOG
        );

        poolSlot0[poolId] = AuctionSlot0.wrap(bytes32(0)).setWinnerFeeSharePart(
            DEFAULT_WINNER_FEE_SHARE
        );

        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _payRent(key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Distributes rent to LPs before each swap.
    /// @notice Returns fee that will be paid to the hook and pays the fee to the strategist.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        AuctionSlot0 slot0 = poolSlot0[poolId];
        address strategy = slot0.strategyAddress();
        uint24 fee = DEFAULT_FEE;
        // If no strategy is set, the swap fee is just set to the default value

        if (strategy == address(0)) {
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(0, 0),
                fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // Call strategy contract to get swap fee.
        try
            IArbiterFeeProvider(strategy).getSwapFee(
                sender,
                key,
                params,
                hookData
            )
        returns (uint24 _fee) {
            if (_fee < 1e6) {
                fee = _fee;
            }
        } catch {}

        int256 totalFees = (params.amountSpecified * int256(uint256(fee))) /
            1e6;
        uint256 absTotalFees = totalFees < 0
            ? uint256(-totalFees)
            : uint256(totalFees);

        // Calculate fee split
        uint256 strategyFee = (absTotalFees * slot0.winnerFeeSharePart()) /
            type(uint16).max;
        uint256 lpFee = absTotalFees - strategyFee;

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;

        Currency feeCurrency = exactOut == params.zeroForOne
            ? key.currency0
            : key.currency1;

        // Send fees to strategy
        vault.mint(strategy, feeCurrency, strategyFee);
        if (exactOut) {
            poolManager.donate(key, lpFee, 0, "");
        } else {
            poolManager.donate(key, 0, lpFee, "");
        }

        // Override LP fee to zero

        return (
            this.beforeSwap.selector,
            exactOut
                ? toBeforeSwapDelta(0, int128(totalFees))
                : toBeforeSwapDelta(0, -int128(totalFees)),
            LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
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

        AuctionSlot1 slot1 = poolSlot1[poolId];
        if (tick != slot1.lastActiveTick()) {
            _payRent(key);
            slot1.setLastActiveTick(tick);
        }

        return (this.afterSwap.selector, 0);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view override returns (Currency) {
        Currency currency = RENT_IN_TOKEN_ZERO ? key.currency0 : key.currency1;

        return currency;
    }

    function _payRent(PoolKey memory key) internal override {
        PoolId poolId = key.toId();
        AuctionSlot0 slot0 = poolSlot0[poolId];
        AuctionSlot1 slot1 = poolSlot1[poolId];

        uint32 lastPaidBlock = slot1.lastPaidBlock();
        uint128 remainingRent = slot1.remainingRent();

        if (lastPaidBlock == uint32(block.number)) {
            return;
        }

        if (remainingRent == 0) {
            slot1 = slot1.setLastPaidBlock(uint32(block.number));
            poolSlot1[poolId] = slot1;

            return;
        }

        // check if we need to change strategy
        if (slot1.shouldChangeStrategy()) {
            slot0 = slot0.setStrategyAddress(winnerStrategies[poolId]);
            slot1 = slot1.setShouldChangeStrategy(false);
        }

        uint32 blocksElapsed;
        unchecked {
            blocksElapsed = uint32(block.number) - lastPaidBlock;
        }

        // overflow unlikely to happen, rentPerBlock is capped at 2^96
        // for overflow to happen 2^128 / rentPerBlock > 2^24 = 194 days
        uint128 rentAmount = slot0.rentPerBlock() * blocksElapsed;

        if (rentAmount > remainingRent) {
            rentAmount = remainingRent;
            winners[poolId] = address(0);
            winnerStrategies[poolId] = address(0);
            slot1 = slot1.setShouldChangeStrategy(true);
            slot0 = slot0.setRentPerBlock(0);
        }

        slot1 = slot1.setLastPaidBlock(uint32(block.number));

        unchecked {
            slot1 = slot1.setRemainingRent(remainingRent - rentAmount);
        }

        // pay the rent
        Currency currency = _getPoolRentCurrency(key);

        vault.burn(address(this), currency, rentAmount);
        poolManager.donate(key, rentAmount, 0, "");

        //TODO only if has changes
        poolSlot1[poolId] = slot1;
        poolSlot0[poolId] = slot0;

        return;
    }
}
