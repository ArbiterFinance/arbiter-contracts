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
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20Minimal} from "pancake-v4-core/src/interfaces/IERC20Minimal.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {Tracker} from "./AbstractTracker.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {PoolExtension} from "./libraries/PoolExtension.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";
import {ILiquididityPerSecondTrackerHook} from "./interfaces/ILiquididityPerSecondTrackerHook.sol";

/// @notice ArbiterAmAmmCakeRentHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmCakeRentHook is
    CLBaseHook,
    Tracker,
    IArbiterAmAmmHarbergerLease
{
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using PositionExtension for PositionExtension.State;
    using PoolExtension for PoolExtension.State;
    using CLPositionInfoLibrary for CLPositionInfo;
    using CLPoolParametersHelper for bytes32;

    /// @notice State used within hooks.
    struct PoolHookState {
        address strategy;
        uint96 rentPerBlock;
    }

    struct RentData {
        uint128 remainingRent;
        uint48 lastPaidBlock;
        uint48 rentEndBlock;
        bool shouldChangeStrategy;
        uint256 rentGrowthGlobalX128;
    }

    mapping(PoolId => PoolHookState) public poolHookStates;
    mapping(PoolId => RentData) public rentDatas;
    mapping(PoolId => address) public winners;
    mapping(PoolId => address) public winnerStrategies;
    mapping(address => uint256) public deposits; // address => amount
    mapping(uint256 => uint256) public accruedRent; // tokenId => accumulated rent

    uint24 constant DEFAULT_SWAP_FEE = 300; // 0.03%
    uint24 constant MAX_FEE = 3000; // 0.3%

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint48 public immutable override MINIMUM_RENT_TIME_IN_BLOCKS;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint64 public immutable override RENT_FACTOR;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint48 public immutable override TRANSTION_BLOCKS;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint256 public immutable override GET_SWAP_FEE_GAS_LIMIT;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint48 public immutable override WINNER_FEE_SHARE;

    IERC20 public rentCurrency; // Rent currency

    constructor(
        ICLPoolManager _poolManager,
        ICLPositionManager _positionManager,
        IERC20 _rentCurrency,
        uint48 _minimumRentTimeInBlocks,
        uint64 _rentFactor,
        uint48 _transitionBlocks,
        uint256 _getSwapFeeGasLimit,
        uint48 _winnerFeeShare
    ) CLBaseHook(_poolManager) Tracker(_poolManager, _positionManager) {
        rentCurrency = _rentCurrency;
        MINIMUM_RENT_TIME_IN_BLOCKS = _minimumRentTimeInBlocks;
        RENT_FACTOR = _rentFactor;
        TRANSTION_BLOCKS = _transitionBlocks;
        GET_SWAP_FEE_GAS_LIMIT = _getSwapFeeGasLimit;
        WINNER_FEE_SHARE = _winnerFeeShare;
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Specify hook permissions.
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
                    afterInitialize: true,
                    beforeAddLiquidity: true,
                    beforeRemoveLiquidity: true,
                    afterAddLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: true,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: true,
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
        int24
    ) external override returns (bytes4) {
        _afterInitializeTracker(key);
        return this.afterInitialize.selector;
    }

    function _afterInitializeTracker(PoolKey calldata key) internal {
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());
        pools[key.toId()].tick = tick;
    }

    /// @dev Reverts if dynamic fee flag is not set.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override poolManagerOnly returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();

        poolHookStates[key.toId()] = PoolHookState({
            strategy: address(1),
            rentPerBlock: 0
        });

        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _updateRentGrowthGlobalX128(key);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _updateRentGrowthGlobalX128(key);
        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Updates pool state after swaps.
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

    /// @notice Distributes rent to LPs before each swap.
    /// @notice Returns fee that will be paid to the hook and pays the fee to the strategist.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address strategy = _updateRentGrowthGlobalX128(key);

        // If no strategy is set, the swap fee is just set to the default fee like in a hookless PancakeSwap pool
        if (strategy == address(0)) {
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(0, 0),
                DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // Call strategy contract to get swap fee.
        uint256 fee = DEFAULT_SWAP_FEE;
        try
            IArbiterFeeProvider(strategy).getSwapFee(sender, key, params, "")
        returns (uint24 _fee) {
            if (_fee > MAX_FEE) {
                fee = MAX_FEE;
            } else {
                fee = _fee;
            }
        } catch {}

        int256 fees = (params.amountSpecified * int256(fee)) /
            1e6 -
            params.amountSpecified;
        uint256 absFees = fees < 0 ? uint256(-fees) : uint256(fees);
        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne
            ? key.currency0
            : key.currency1;

        // Send fees to `strategy`
        vault.mint(strategy, feeCurrency, absFees);

        // Override LP fee to zero
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(fees), 0),
            LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// AmAMM //////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments as the manager.
    function _deposit(uint256 amount) internal {
        // Transfer rentCurrency tokens from msg.sender to this contract
        require(
            rentCurrency.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        deposits[msg.sender] += amount;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function overbid(
        PoolKey calldata key,
        uint96 rent,
        uint48 rentEndBlock,
        address strategy
    ) external {
        if (rentEndBlock < uint48(block.number) + MINIMUM_RENT_TIME_IN_BLOCKS) {
            revert RentTooLow();
        }

        RentData storage rentData = rentDatas[key.toId()];
        PoolHookState storage hookState = poolHookStates[key.toId()];
        if (block.number < rentData.rentEndBlock - TRANSTION_BLOCKS) {
            uint96 minimumRent = uint96(
                (hookState.rentPerBlock * RENT_FACTOR) / 1e6
            );
            if (rent <= minimumRent) {
                revert RentTooLow();
            }
        }

        _updateRentGrowthGlobalX128(key);

        // Refund the remaining rent to the previous winner
        deposits[winners[key.toId()]] += rentData.remainingRent;

        // Charge the new winner
        uint128 requiredDeposit = rent * (rentEndBlock - uint48(block.number));
        uint256 availableDeposit = deposits[msg.sender];
        if (availableDeposit < requiredDeposit) {
            revert InsufficientDeposit();
        }
        deposits[msg.sender] = availableDeposit - requiredDeposit;

        // Set up new rent
        rentData.remainingRent = requiredDeposit;
        rentData.rentEndBlock = rentEndBlock;
        rentData.shouldChangeStrategy = true;
        hookState.rentPerBlock = rent;

        rentDatas[key.toId()] = rentData;
        poolHookStates[key.toId()] = hookState;
        winners[key.toId()] = msg.sender;
        winnerStrategies[key.toId()] = strategy;
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `makeDeposit`.
    function withdraw(address asset, uint256 amount) external {
        if (asset != address(rentCurrency)) {
            revert("Invalid asset");
        }
        uint256 senderDeposit = deposits[msg.sender];
        if (senderDeposit < amount) {
            revert InsufficientDeposit();
        }
        deposits[msg.sender] = senderDeposit - amount;

        // Transfer rentCurrency tokens from this contract to msg.sender
        require(rentCurrency.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Claim accumulated rent for a given position
    function claimRent(uint256 tokenId, address to) external {
        require(
            IERC721(address(positionManager)).ownerOf(tokenId) == msg.sender,
            "Not owner"
        );

        // Get position info
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();
        PositionExtension.State storage position = positions[tokenId];
        PoolExtension.State storage pool = pools[poolId];

        _updateRentGrowthGlobalX128(poolKey);

        // Calculate seconds per liquidity inside
        uint256 secondsPerLiquidityInsideX128 = pool
            .getSecondsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            );

        // Calculate rent owed
        uint256 secondsInRangeX128 = secondsPerLiquidityInsideX128 -
            position.secondsPerLiquidityLastX128;
        uint256 rentOwed = (secondsInRangeX128 *
            position.liquidity *
            rentDatas[poolId].rentGrowthGlobalX128) /
            FixedPoint128.Q128 /
            FixedPoint128.Q128;

        // Update position's secondsPerLiquidityLastX128
        position.secondsPerLiquidityLastX128 = secondsPerLiquidityInsideX128;

        // Add any accrued rent from modify liquidity
        rentOwed += accruedRent[tokenId];
        accruedRent[tokenId] = 0;

        if (rentOwed > 0) {
            // Transfer rentCurrency tokens to 'to' address
            require(
                rentCurrency.balanceOf(address(this)) >= rentOwed,
                "Insufficient rent balance"
            );
            require(rentCurrency.transfer(to, rentOwed), "Transfer failed");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @dev Must be called while lock is acquired.
    function _updateRentGrowthGlobalX128(
        PoolKey memory key
    ) internal returns (address) {
        RentData storage rentData = rentDatas[key.toId()];
        PoolHookState storage hookState = poolHookStates[key.toId()];

        if (rentData.lastPaidBlock == block.number) {
            return hookState.strategy;
        }

        // Check if we need to change strategy
        if (rentData.shouldChangeStrategy) {
            hookState.strategy = winners[key.toId()];
            rentData.shouldChangeStrategy = false;
        }

        uint48 blocksElapsed;
        if (rentData.rentEndBlock <= uint48(block.number)) {
            blocksElapsed = rentData.rentEndBlock - rentData.lastPaidBlock;
            winners[key.toId()] = address(0);
            rentData.shouldChangeStrategy = true;
            hookState.rentPerBlock = 0;
        } else {
            blocksElapsed = uint48(block.number) - rentData.lastPaidBlock;
        }

        rentData.lastPaidBlock = uint48(block.number);

        uint128 rentAmount = hookState.rentPerBlock * blocksElapsed;

        rentData.remainingRent -= rentAmount;

        if (rentAmount == 0) {
            return hookState.strategy;
        }

        // Update rentGrowthGlobalX128
        rentData.rentGrowthGlobalX128 += uint256(rentAmount) << 128;

        // Rent remains in the contract until claimed by LPs

        return hookState.strategy;
    }

    function _afterSwapTracker(PoolKey calldata key) internal {
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());
        pools[key.toId()].crossToActiveTick(
            key.parameters.getTickSpacing(),
            tick
        );
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ISubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function notifyModifyLiquidity(
        uint256 tokenId,
        int256 liquidityDelta,
        BalanceDelta
    ) external override {
        _onModifyLiquidityTracker(tokenId, liquidityDelta);

        // Get the poolId associated with the position
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();
        PoolExtension.State storage pool = pools[poolId];
        PositionExtension.State storage position = positions[tokenId];

        _updateRentGrowthGlobalX128(poolKey);

        if (liquidityDelta != 0) {
            // Update position's rent tracking
            uint256 secondsPerLiquidityInsideX128 = pool
                .getSecondsPerLiquidityInsideX128(
                    positionInfo.tickLower(),
                    positionInfo.tickUpper()
                );

            if (liquidityDelta > 0) {
                // Adding liquidity
                position
                    .secondsPerLiquidityLastX128 = secondsPerLiquidityInsideX128;
            } else {
                // Removing liquidity, calculate rent owed
                uint256 secondsInRangeX128 = secondsPerLiquidityInsideX128 -
                    position.secondsPerLiquidityLastX128;
                uint256 rentOwed = (secondsInRangeX128 *
                    position.liquidity *
                    rentDatas[poolId].rentGrowthGlobalX128) /
                    FixedPoint128.Q128 /
                    FixedPoint128.Q128;

                if (rentOwed > 0) {
                    accruedRent[tokenId] += rentOwed;
                }

                // Reset position's secondsPerLiquidityLastX128
                position
                    .secondsPerLiquidityLastX128 = secondsPerLiquidityInsideX128;
            }
        }
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function changeStrategy(
        PoolKey calldata key,
        address strategy
    ) external override {
        if (msg.sender != winners[key.toId()]) {
            revert CallerNotWinner();
        }
        poolHookStates[key.toId()].strategy = strategy;
        rentDatas[key.toId()].shouldChangeStrategy = true;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function biddingCurrency(
        PoolKey calldata key
    ) external view override returns (address) {
        return address(rentCurrency);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function activeStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        return poolHookStates[key.toId()].strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        return winnerStrategies[key.toId()];
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winner(
        PoolKey calldata key
    ) external view override returns (address) {
        return winners[key.toId()];
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentPerBlock(
        PoolKey calldata key
    ) external view override returns (uint96) {
        return poolHookStates[key.toId()].rentPerBlock;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentEndBlock(
        PoolKey calldata key
    ) external view override returns (uint48) {
        return rentDatas[key.toId()].rentEndBlock;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function deposit(address asset, uint256 amount) external {
        if (asset != address(rentCurrency)) {
            revert("Invalid asset");
        }
        _deposit(amount);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function depositOf(
        address asset,
        address account
    ) external view override returns (uint256) {
        return deposits[account];
    }

    /// @inheritdoc ILiquididityPerSecondTrackerHook
    function getSecondsPerLiquidityCumulativeX128(
        PoolKey calldata key
    ) external view override returns (uint256) {
        return rentDatas[key.toId()].rentGrowthGlobalX128; //TODO!!!!!
    }

    /// @inheritdoc ILiquididityPerSecondTrackerHook
    function getSecondsPerLiquidityInsideX128(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (uint256) {
        return
            pools[key.toId()].getSecondsPerLiquidityInsideX128(
                tickLower,
                tickUpper
            );
    }
}
