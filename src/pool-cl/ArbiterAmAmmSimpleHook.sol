// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "pancake-v4-core/src/interfaces/IERC20Minimal.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";

uint24 constant DEFAULT_SWAP_FEE = 300; // 0.03%
uint24 constant MAX_FEE = 10000; // 1.0%

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalites.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmSimpleHook is CLBaseHook, IArbiterAmAmmHarbergerLease {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error InitData();
    error NotDynamicFee();
    error ToSmallDeposit();
    error AlreadyWinning();
    error RentTooLow();

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
        uint24 rentConfig; // could store additional data
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        address currency;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => PoolHookState) public poolHookStates;
    mapping(PoolId => RentData) public rentDatas;
    mapping(PoolId => address) public winners;
    mapping(PoolId => uint256) public winnerStrategies;
    mapping(address => mapping(Currency => uint256)) public deposits;

    bool immutable RENT_IN_TOKEN_ZERO;
    constructor(
        ICLPoolManager _poolManager,
        uint48 _minimumRentTimeInBlocks,
        uint64 _rentFactor,
        uint48 _transitionBlocks,
        uint256 _getSwapFeeGasLimit,
        bool _rentInTokenZero
    ) CLBaseHook(_poolManager) {
        MINIMUM_RENT_TIME_IN_BLOCKS = _minimumRentTimeInBlocks;
        RENT_FACTOR = _rentFactor;
        TRANSTION_BLOCKS = _transitionBlocks;
        GET_SWAP_FEE_GAS_LIMIT = _getSwapFeeGasLimit;
        RENT_IN_TOKEN_ZERO = _rentInTokenZero;

        require(
            uint16(uint160(address(this)) >> 144) == getHookPermissionsBitmap(),
            "hookAddress mismatch"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHookPermissionsBitmap() public pure returns (uint16) {
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
                    afterRemoveLiquidiyReturnsDelta: false
                })
            );
    }

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not intialized with dynamic fees.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override poolManagerOnly returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        if (data.length != 1) revert InitData();

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
        _payRent(key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Distributes rent to LPs before each swap.
    /// @notice Returns fee what will be paid to the hook and pays the fee to the strategist.
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
        address strategy = _payRent(key);

        // If no strategy is set, the swap fee is just set to the default fee Uniswap pool
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
            IArbiterFeeProvider(strategy).getSwapFee(
                sender,
                key,
                params,
                hookData
            )
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
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        // TODO: check if this is correct

        uint256 feesForLps = 0;
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne
            ? key.currency0
            : key.currency1;

        // // Send fees to `feeRecipient`
        _payRent(key, feesForLps);
        poolManager.mint(strategy, feeCurrency.toId(), absFees);

        // Override LP fee to zero
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(fees), 0),
            LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////
    /////////////////////////// IArbiterAmAmmHarbergerLease ///////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint48 public immutable override MINIMUM_RENT_TIME_IN_BLOCKS;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint64 public immutable override RENT_FACTOR;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint48 public immutable override TRANSTION_BLOCKS;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    uint256 public immutable override GET_SWAP_FEE_GAS_LIMIT;

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function depositOf(
        address asset,
        address account
    ) external view override returns (uint256) {
        return deposits[account][Currency(asset)];
    }

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view returns (Currency) {
        return RENT_IN_TOKEN_ZERO ? key.currency0 : key.currency1;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function biddingCurrency(
        PoolKey calldata key
    ) external view override returns (address) {
        return address(_getPoolRentCurrency(key));
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
        return poolHookStates[key.toId()].winnerStrategy;
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
    function deposit(address asset, uint256 amount) external override {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        poolManager.lock(
            abi.encode(CallbackData(asset, msg.sender, amount, 0))
        );
        deposits[msg.sender][Currency(asset)] += amount;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function overbid(
        PoolKey calldata key,
        uint96 rent,
        uint48 rentEndBlockNumber,
        address strategy
    ) external {
        require(
            rentEndBlockNumber >= block.number + MINIMUM_RENT_TIME_IN_BLOCKS,
            "Rent too short"
        );
        (uint160 price, , , ) = poolManager.getSlot0(key.toId());
        require(price != 0, "Pool not initialized");

        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];
        if (block.number < rentData.rentEndBlock - TRANSTION_BLOCKS) {
            require(
                rent > (hookState.rentPerBlock * RENT_FACTOR) / 1e6,
                "Rent too low"
            );
        }

        _payRent(key);

        Currency currency = _getPoolRentCurrency(key);

        // refund the remaining rent to the previous winner
        deposits[winners[key.toId()]][currency] += rentData.remainingRent;

        // charge the new winner
        uint128 requiredDeposit = rent *
            (rentEndBlockNumber - uint48(block.number));
        unchecked {
            require(
                deposits[msg.sender][currency] >= requiredDeposit,
                "Deposit too low"
            );
            deposits[msg.sender][currency] -= requiredDeposit;
        }

        // set up new rent
        rentData.remainingRent = requiredDeposit;
        rentData.rentEndBlock = rentEndBlockNumber;
        rentData.changeStrategy = true;
        hookState.rentPerBlock = rent;

        rentDatas[key.toId()] = rentData;
        poolHookStates[key.toId()] = hookState;
        winners[key.toId()] = msg.sender;
        winnerStrategies[key.toId()] = strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function withdraw(address asset, uint256 amount) external override {
        uint256 depositAmount = deposits[msg.sender][Currency(asset)];
        unchecked {
            require(depositAmount >= amount, "Deposit too low");
            deposits[msg.sender][Currency(asset)] = depositAmount - amount;
        }
        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        poolManager.lock(
            abi.encode(CallbackData(asset, msg.sender, 0, amount))
        );
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function changeStrategy(
        PoolKey calldata key,
        address strategy
    ) external override {
        require(msg.sender == winners[key.toId()], "Not winner");
        poolHookStates[key.toId()].strategy = strategy;
        rentDatas[key.toId()].changeStrategy = true;
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Callback ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function lockAcquired(
        bytes calldata rawData
    ) external override vaultOnly returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        if (data.depositAmount > 0) {
            poolManager.burn(
                data.sender,
                Currency(data.currency).toId(),
                data.depositAmount
            );
            poolManager.mint(
                address(this),
                Currency(data.currency),
                data.depositAmount
            );
        }
        if (data.withdrawAmount > 0) {
            poolManager.burn(
                address(this),
                Currency(data.currency),
                data.withdrawAmount
            );
            poolManager.mint(
                data.sender,
                Currency(data.currency),
                data.withdrawAmount
            );
        }
        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Donates rent plus rent swapFeeToLP to the pool.
    /// @dev Must be called while lock is acquired.
    /// @param key Pool key.
    /// @param swapFeeToLP amount of swap fee to be paid to LPs.
    /// @return address of the strategy to be used for the next swap.
    function _payRent(
        PoolKey memory key,
        uint128 swapFeeToLP
    ) internal returns (address) {
        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];

        if (
            rentData.lastPaidBlock == block.number ||
            rentData.lastPaidBlock >= rentData.rentEndBlock
        ) {
            return hookState.strategy;
        }

        bool hookStateChanged = false;
        // check if we need to change strategy
        if (rentData.changeStrategy) {
            hookState.strategy = winnerStrategies[key.toId()];
            rentData.changeStrategy = false;
            hookStateChanged = true;
        }

        uint48 blocksElapsed;
        if (rentData.rentEndBlock <= uint48(block.number)) {
            blocksElapsed = rentData.rentEndBlock - rentData.lastPaidBlock;
            winners[key.toId()] = address(0);
            winnerStrategies[key.toId()] = address(0);
            rentData.changeStrategy = true;
            hookState.rentPerBlock = 0;
            hookStateChanged = true;
        } else {
            blocksElapsed = uint48(block.number) - rentData.lastPaidBlock;
        }

        rentData.lastPaidBlock = uint48(block.number);

        uint128 rentAmount = hookState.rentPerBlock * blocksElapsed;

        rentData.remainingRent -= rentAmount;

        if (rentAmount != 0) {
            // pay the rent
            Currency currency = _getPoolRentCurrency(key);

            poolManager.burn(address(this), currency.toId(), rentAmount);
            poolManager.donate(key, rentAmount, 0, "");
        }

        rentDatas[key.toId()] = rentData;
        if (hookStateChanged) {
            poolHookStates[key.toId()] = hookState;
        }

        return hookState.strategy;
    }
}
