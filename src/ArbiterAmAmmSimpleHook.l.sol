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

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";

uint24 constant DEFAULT_SWAP_FEE = 300; // 0.03%
uint24 constant MAX_FEE = 10000; // 1.0%

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmSimpleHook is CLBaseHook, IArbiterAmAmmHarbergerLease {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

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
    mapping(PoolId => address) public winnerStrategies;
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
        console.log("Constructor start");
        console.log("_minimumRentTimeInBlocks", _minimumRentTimeInBlocks);
        console.log("_rentFactor", _rentFactor);
        console.log("_transitionBlocks", _transitionBlocks);
        console.log("_getSwapFeeGasLimit", _getSwapFeeGasLimit);
        console.log("_rentInTokenZero", _rentInTokenZero);
        MINIMUM_RENT_TIME_IN_BLOCKS = _minimumRentTimeInBlocks;
        RENT_FACTOR = _rentFactor;
        TRANSTION_BLOCKS = _transitionBlocks;
        GET_SWAP_FEE_GAS_LIMIT = _getSwapFeeGasLimit;
        RENT_IN_TOKEN_ZERO = _rentInTokenZero;
        console.log("Constructor end");

        // require(
        //     uint16(uint160(address(this)) >> 144) == getHookPermissionsBitmap(),
        //     "hookAddress mismatch"
        // );
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
        console.log("beforeInitialize start");
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();

        poolHookStates[key.toId()] = PoolHookState({
            strategy: address(0),
            rentPerBlock: 0
        });
        console.log("beforeInitialize end");
        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        console.log("beforeAddLiquidity start");
        _payRent(key);
        console.log("beforeAddLiquidity end");
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
        console.log("beforeSwap start");
        address strategy = _payRent(key);

        // If no strategy is set, the swap fee is just set to the default value
        console.log("setting fee strategy");
        if (strategy == address(0)) {
            console.log("no strategy - setting default fee");
            console.log("beforeSwap end");
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
        console.log("after strategy call");
        console.log("fee", fee);

        int256 fees = (params.amountSpecified * int256(fee)) / 1e6;
        uint256 absFees = fees < 0 ? uint256(-fees) : uint256(fees);

        console.log("fees", fees);
        console.log("absFees", absFees);

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.

        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne
            ? key.currency0
            : key.currency1;

        console.log("feeCurrency", Currency.unwrap(feeCurrency));

        // Send fees to `feeRecipient`
        vault.mint(strategy, feeCurrency, absFees);

        // Override LP fee to zero
        console.log("beforeSwap end");
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
        console.log("depositOf start");
        uint256 depositAmount = deposits[account][Currency.wrap(asset)];
        console.log("depositOf end");
        return depositAmount;
    }

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view returns (Currency) {
        console.log("_getPoolRentCurrency start");
        Currency currency = RENT_IN_TOKEN_ZERO ? key.currency0 : key.currency1;
        console.log("_getPoolRentCurrency end");
        return currency;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function biddingCurrency(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("biddingCurrency start");
        address currency = Currency.unwrap(_getPoolRentCurrency(key));
        console.log("biddingCurrency end");
        return currency;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function activeStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("activeStrategy start");
        address strategy = poolHookStates[key.toId()].strategy;
        console.log("activeStrategy end");
        return strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("winnerStrategy start");
        address strategy = winnerStrategies[key.toId()];
        console.log("winnerStrategy end");
        return strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winner(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("winner start");
        address winnerAddr = winners[key.toId()];
        console.log("winner end");
        return winnerAddr;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentPerBlock(
        PoolKey calldata key
    ) external view override returns (uint96) {
        console.log("rentPerBlock start");
        uint96 rent = poolHookStates[key.toId()].rentPerBlock;
        console.log("rentPerBlock end");
        return rent;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentEndBlock(
        PoolKey calldata key
    ) external view override returns (uint48) {
        console.log("rentEndBlock start");
        uint48 endBlock = rentDatas[key.toId()].rentEndBlock;
        console.log("rentEndBlock end");
        return endBlock;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function deposit(address asset, uint256 amount) external override {
        console.log("deposit start");
        console.log("asset", asset);
        console.log("amount", amount);
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        vault.lock(abi.encode(CallbackData(asset, msg.sender, amount, 0)));
        deposits[msg.sender][Currency.wrap(asset)] += amount;
        console.log("deposit end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function overbid(
        PoolKey calldata key,
        uint96 rent,
        uint48 rentEndBlock,
        address strategy
    ) external {
        console.log("overbid start");
        console.log("rent", rent);
        console.log("rentEndBlock", rentEndBlock);
        console.log("strategy", strategy);
        uint48 minimumEndBlock = uint48(block.number) +
            MINIMUM_RENT_TIME_IN_BLOCKS;
        if (rentEndBlock < minimumEndBlock) {
            revert RentTooShort();
        }
        (uint160 price, , , ) = poolManager.getSlot0(key.toId());
        if (price == 0) {
            revert PoolNotInitialized();
        }

        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];
        if (
            rentData.rentEndBlock != 0 &&
            block.number < rentData.rentEndBlock - TRANSTION_BLOCKS
        ) {
            uint96 minimumRent = uint96(
                (hookState.rentPerBlock * RENT_FACTOR) / 1e6
            );
            if (rent <= minimumRent) {
                revert RentTooLow();
            }
        }

        _payRent(key);

        Currency currency = _getPoolRentCurrency(key);

        // refund the remaining rent to the previous winner
        deposits[winners[key.toId()]][currency] += rentData.remainingRent;

        // charge the new winner
        uint128 requiredDeposit = rent * (rentEndBlock - uint48(block.number));
        unchecked {
            uint256 availableDeposit = deposits[msg.sender][currency];
            if (availableDeposit < requiredDeposit) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][currency] = availableDeposit - requiredDeposit;
        }

        // set up new rent
        rentData.remainingRent = requiredDeposit;
        rentData.rentEndBlock = rentEndBlock;
        rentData.shouldChangeStrategy = true;
        hookState.rentPerBlock = rent;

        rentDatas[key.toId()] = rentData;
        poolHookStates[key.toId()] = hookState;
        winners[key.toId()] = msg.sender;
        winnerStrategies[key.toId()] = strategy;
        console.log("overbid end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function withdraw(address asset, uint256 amount) external override {
        console.log("withdraw start");
        console.log("asset", asset);
        console.log("amount", amount);
        uint256 depositAmount = deposits[msg.sender][Currency.wrap(asset)];
        unchecked {
            if (depositAmount < amount) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][Currency.wrap(asset)] = depositAmount - amount;
        }
        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        vault.lock(abi.encode(CallbackData(asset, msg.sender, 0, amount)));
        console.log("withdraw end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function changeStrategy(
        PoolKey calldata key,
        address strategy
    ) external override {
        console.log("changeStrategy start");
        if (msg.sender != winners[key.toId()]) {
            revert CallerNotWinner();
        }
        poolHookStates[key.toId()].strategy = strategy;
        rentDatas[key.toId()].shouldChangeStrategy = true;
        console.log("changeStrategy end");
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Callback ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function lockAcquired(
        bytes calldata rawData
    ) external override vaultOnly returns (bytes memory) {
        console.log("lockAcquired start");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        console.log("data.currency", data.currency);
        console.log("data.sender", data.sender);
        console.log("data.depositAmount", data.depositAmount);
        console.log("data.withdrawAmount", data.withdrawAmount);
        if (data.depositAmount > 0) {
            vault.sync(Currency.wrap(data.currency));
            // Transfer tokens directly from msg.sender to the vault
            IERC20(data.currency).transferFrom(
                data.sender,
                address(vault),
                data.depositAmount
            );
            vault.mint(
                address(this),
                Currency.wrap(data.currency),
                data.depositAmount
            );
            vault.settle();
        }
        if (data.withdrawAmount > 0) {
            vault.burn(
                address(this),
                Currency.wrap(data.currency),
                data.withdrawAmount
            );
            vault.mint(
                data.sender,
                Currency.wrap(data.currency),
                data.withdrawAmount
            );
            vault.settle();
        }
        console.log("lockAcquired end");
        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Donates rent plus rent swapFeeToLP to the pool.
    /// @dev Must be called while lock is acquired.
    /// @param key Pool key.
    /// @return address of the strategy to be used for the next swap.
    function _payRent(PoolKey memory key) internal returns (address) {
        console.log("_payRent start");
        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];
        console.log("rentData.lastPaidBlock", rentData.lastPaidBlock);
        console.log("rentData.rentEndBlock", rentData.rentEndBlock);
        console.log("hookState.strategy", hookState.strategy);
        console.log("hookState.rentPerBlock", hookState.rentPerBlock);

        if (
            (rentData.lastPaidBlock == block.number ||
                rentData.lastPaidBlock >= rentData.rentEndBlock)
        ) {
            console.log("_payRent end (early return)");
            return hookState.strategy;
        }

        bool hookStateChanged = false;
        // check if we need to change strategy
        if (rentData.shouldChangeStrategy) {
            hookState.strategy = winnerStrategies[key.toId()];
            rentData.shouldChangeStrategy = false;
            hookStateChanged = true;
            console.log("Strategy changed to", hookState.strategy);
        }

        uint48 blocksElapsed;
        if (rentData.rentEndBlock <= uint48(block.number)) {
            blocksElapsed = rentData.rentEndBlock - rentData.lastPaidBlock;
            winners[key.toId()] = address(0);
            winnerStrategies[key.toId()] = address(0);
            rentData.shouldChangeStrategy = true;
            hookState.rentPerBlock = 0;
            hookStateChanged = true;
            console.log("Rent period ended, resetting winner and strategy");
        } else {
            blocksElapsed = uint48(block.number) - rentData.lastPaidBlock;
        }

        console.log("blocksElapsed", blocksElapsed);

        rentData.lastPaidBlock = uint48(block.number);

        uint128 rentAmount = hookState.rentPerBlock * blocksElapsed;

        console.log("rentAmount", rentAmount);

        rentData.remainingRent -= rentAmount;

        if (rentAmount != 0) {
            // pay the rent
            Currency currency = _getPoolRentCurrency(key);
            console.log(
                "Paying rentAmount",
                rentAmount,
                "in currency",
                Currency.unwrap(currency)
            );

            vault.burn(address(this), currency, rentAmount);
            poolManager.donate(key, rentAmount, 0, "");
        }

        rentDatas[key.toId()] = rentData;
        if (hookStateChanged) {
            poolHookStates[key.toId()] = hookState;
        }

        console.log("_payRent end");
        return hookState.strategy;
    }
}
