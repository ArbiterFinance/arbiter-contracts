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

/// TODO decide on the blockNumber storage size uint32 / uint48 / uint64

uint8 constant DEFAULT_WINNER_FEE_SHARE = 6; // 6/127 ~= 4.72%
uint8 constant DEFAULT_GET_SWAP_FEE_LOG = 13; // 2^13 = 8192
uint24 constant DEFAULT_MAX_POOL_SWAP_FEE = 10000; // 1.0%
uint16 constant DEFAULT_DEFAULT_POOL_SWAP_FEE = 300; // 0.03%
uint8 constant DEFAULT_OVERBID_FACTOR = 4; // 4/127 ~= 3.15%
uint8 constant DEFAULT_TRANSITION_BLOCKS = 20;
uint16 constant DEFAULT_MINIMUM_RENT_BLOCKS = 300;

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmSimpleHook is
    CLBaseHook,
    IArbiterAmAmmHarbergerLease,
    Ownable2Step
{
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using AuctionSlot0Library for AuctionSlot0;
    using AuctionSlot1Library for AuctionSlot1;

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        address currency;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => AuctionSlot0) public poolSlot0;
    mapping(PoolId => AuctionSlot1) public poolSlot1;
    mapping(PoolId => address) public winners;
    mapping(PoolId => address) public winnerStrategies;
    mapping(address => mapping(Currency => uint256)) public deposits;

    bool immutable RENT_IN_TOKEN_ZERO;
    constructor(
        ICLPoolManager _poolManager,
        bool _rentInTokenZero,
        address _initOwner
    ) CLBaseHook(_poolManager) Ownable(_initOwner) {
        console.log("[Constructor] Constructor start");

        RENT_IN_TOKEN_ZERO = _rentInTokenZero;
        console.log("[Constructor] Constructor end");
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
        console.log("[beforeInitialize] beforeInitialize start");
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();

        AuctionSlot0 slot0 = AuctionSlot0.wrap(bytes32(0));

        slot0
            .setStrategyAddress(address(0))
            .setStrategyGasLimit(DEFAULT_GET_SWAP_FEE_LOG)
            .setWinnerFeeShare(DEFAULT_WINNER_FEE_SHARE)
            .setMaxSwapFee(DEFAULT_MAX_POOL_SWAP_FEE)
            .setDefaultSwapFee(DEFAULT_DEFAULT_POOL_SWAP_FEE)
            .setOverbidFactor(DEFAULT_OVERBID_FACTOR)
            .setTransitionBlocks(DEFAULT_TRANSITION_BLOCKS)
            .setMinRentBlocks(DEFAULT_MINIMUM_RENT_BLOCKS);

        poolSlot0[key.toId()] = slot0;
        console.log("[beforeInitialize] beforeInitialize end");
        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        console.log("[beforeAddLiquidity] beforeAddLiquidity start");
        _payRent(key);
        console.log("[beforeAddLiquidity] beforeAddLiquidity end");
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
        console.log("[beforeSwap] beforeSwap start");
        AuctionSlot0 slot0 = _payRent(key);
        address strategy = slot0.strategyAddress();
        uint24 fee = slot0.defaultSwapFee();
        // If no strategy is set, the swap fee is just set to the default value
        console.log("[beforeSwap] setting fee strategy");
        if (strategy == address(0)) {
            console.log("[beforeSwap] no strategy - setting default fee");
            console.log("[beforeSwap] beforeSwap end");
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
            uint24 maxFee = slot0.maxSwapFee();
            if (_fee > maxFee) {
                fee = maxFee;
            } else {
                fee = _fee;
            }
        } catch {}
        console.log("[beforeSwap] after strategy call");
        console.log("[beforeSwap] fee", fee);

        int256 totalFees = (params.amountSpecified * int256(uint256(fee))) /
            1e6;
        uint256 absTotalFees = totalFees < 0
            ? uint256(-totalFees)
            : uint256(totalFees);

        // Calculate fee split
        uint256 strategyFee = (absTotalFees * slot0.winnerFeeSharePart()) / 127;
        uint256 lpFee = absTotalFees - strategyFee;

        console.log("[beforeSwap] totalFees", totalFees);
        console.log("[beforeSwap] strategyFee", strategyFee);
        console.log("[beforeSwap] lpFee", lpFee);

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;

        Currency feeCurrency = exactOut == params.zeroForOne
            ? key.currency0
            : key.currency1;

        console.log("[beforeSwap] feeCurrency", Currency.unwrap(feeCurrency));
        console.log("[beforeSwap] exactOut", exactOut);
        console.log(
            "[beforeSwap] params.amountSpecified",
            params.amountSpecified
        );

        // Send fees to strategy
        vault.mint(strategy, feeCurrency, strategyFee);
        if (exactOut) {
            poolManager.donate(key, lpFee, 0, "");
        } else {
            poolManager.donate(key, 0, lpFee, "");
        }

        // Override LP fee to zero
        console.log("[beforeSwap] beforeSwap end");
        return (
            this.beforeSwap.selector,
            exactOut
                ? toBeforeSwapDelta(0, int128(totalFees))
                : toBeforeSwapDelta(0, -int128(totalFees)),
            LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////
    /////////////////////////// IArbiterAmAmmHarbergerLease ///////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function minimumRentBlocks(
        PoolKey calldata key
    ) external view returns (uint64) {
        return poolSlot0[key.toId()].minRentBlocks();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentFactor(PoolKey calldata key) external view returns (uint8) {
        return poolSlot0[key.toId()].overbidFactor();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function transitionBlocks(
        PoolKey calldata key
    ) external view returns (uint64) {
        return poolSlot0[key.toId()].transitionBlocks();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function getFeeGasLimit(
        PoolKey calldata key
    ) external view returns (uint256) {
        return poolSlot0[key.toId()].strategyGasLimit();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerFeeShare(
        PoolKey calldata key
    ) external view returns (uint8) {
        return poolSlot0[key.toId()].winnerFeeSharePart();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function depositOf(
        address asset,
        address account
    ) external view override returns (uint256) {
        console.log("[depositOf] depositOf start");
        uint256 depositAmount = deposits[account][Currency.wrap(asset)];
        console.log("[depositOf] depositOf end");
        return depositAmount;
    }

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view returns (Currency) {
        console.log("[_getPoolRentCurrency] _getPoolRentCurrency start");
        Currency currency = RENT_IN_TOKEN_ZERO ? key.currency0 : key.currency1;
        console.log("[_getPoolRentCurrency] _getPoolRentCurrency end");
        return currency;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function biddingCurrency(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("[biddingCurrency] biddingCurrency start");
        address currency = Currency.unwrap(_getPoolRentCurrency(key));
        console.log("[biddingCurrency] biddingCurrency end");
        return currency;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function activeStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("[activeStrategy] activeStrategy start");
        address strategy = poolSlot0[key.toId()].strategyAddress();
        console.log("[activeStrategy] activeStrategy end");
        return strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("[winnerStrategy] winnerStrategy start");
        address strategy = winnerStrategies[key.toId()];
        console.log("[winnerStrategy] winnerStrategy end");
        return strategy;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winner(
        PoolKey calldata key
    ) external view override returns (address) {
        console.log("[winner] winner start");
        address winnerAddr = winners[key.toId()];
        console.log("[winner] winner end");
        return winnerAddr;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function currentRentPerBlock(
        PoolKey calldata key
    ) external view override returns (uint96) {
        console.log("[rentPerBlock] rentPerBlock start");
        uint96 rent = poolSlot1[key.toId()].rentPerBlock();
        console.log("[rentPerBlock] rentPerBlock end");
        return rent;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function currentRentEndBlock(
        PoolKey calldata key
    ) external view override returns (uint48) {
        console.log("[rentEndBlock] rentEndBlock start");
        uint64 endBlock = poolSlot1[key.toId()].rentEndBlock();
        console.log("[rentEndBlock] rentEndBlock end");
        return uint48(endBlock);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function deposit(address asset, uint256 amount) external override {
        console.log("[deposit] deposit start");
        console.log("[deposit] asset", asset);
        console.log("[deposit] amount", amount);
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        vault.lock(abi.encode(CallbackData(asset, msg.sender, amount, 0)));
        deposits[msg.sender][Currency.wrap(asset)] += amount;
        console.log("[deposit] deposit end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function overbid(
        PoolKey calldata key,
        uint96 rentPerBlock,
        uint48 rentEndBlock,
        address strategy
    ) external {
        console.log("[overbid] overbid start");
        console.log("[overbid] rentPerBlock", rentPerBlock);
        console.log("[overbid] rentEndBlock", rentEndBlock);
        console.log("[overbid] strategy", strategy);
        (uint160 price, , , ) = poolManager.getSlot0(key.toId());
        if (price == 0) {
            revert PoolNotInitialized();
        }

        AuctionSlot0 slot0 = poolSlot0[key.toId()];
        AuctionSlot1 slot1 = poolSlot1[key.toId()];

        uint64 minimumEndBlock = uint64(block.number) + slot0.minRentBlocks();
        if (rentEndBlock < minimumEndBlock) {
            revert RentTooShort();
        }

        uint64 _currentRentEndBlock = slot1.rentEndBlock();
        if (block.number < _currentRentEndBlock - slot0.transitionBlocks()) {
            uint96 minimumRentPerBlock = uint96(
                (slot1.rentPerBlock() * slot0.overbidFactor()) / 127
            );
            if (rentPerBlock <= minimumRentPerBlock) {
                revert RentTooLow();
            }
        }

        _payRent(key);

        Currency currency = _getPoolRentCurrency(key);

        // refund the remaining rentPerBlock to the previous winner
        deposits[winners[key.toId()]][currency] += slot1.remainingRent();

        // charge the new winner
        uint64 rentBlockLength = rentEndBlock - uint64(block.number);
        uint120 requiredDeposit = rentPerBlock * rentBlockLength;
        unchecked {
            uint256 availableDeposit = deposits[msg.sender][currency];
            if (availableDeposit < requiredDeposit) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][currency] = availableDeposit - requiredDeposit;
        }

        // set up new rent
        slot1.setRemainingRent(requiredDeposit);
        slot1.setShouldChangeStrategy(true);
        slot1.setRentPerBlock(rentPerBlock);

        poolSlot1[key.toId()] = slot1;
        winners[key.toId()] = msg.sender;
        winnerStrategies[key.toId()] = strategy;
        console.log("[overbid] overbid end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function withdraw(address asset, uint256 amount) external override {
        console.log("[withdraw] withdraw start");
        console.log("[withdraw] asset", asset);
        console.log("[withdraw] amount", amount);
        uint256 depositAmount = deposits[msg.sender][Currency.wrap(asset)];
        unchecked {
            if (depositAmount < amount) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][Currency.wrap(asset)] = depositAmount - amount;
        }
        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        vault.lock(abi.encode(CallbackData(asset, msg.sender, 0, amount)));
        console.log("[withdraw] withdraw end");
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function changeStrategy(
        PoolKey calldata key,
        address strategy
    ) external override {
        console.log("[changeStrategy] changeStrategy start");
        if (
            msg.sender != winners[key.toId()] ||
            poolSlot1[key.toId()].rentEndBlock() <= block.number
        ) {
            revert CallerNotWinner();
        }
        winnerStrategies[key.toId()] = strategy;
        poolSlot1[key.toId()].setShouldChangeStrategy(true);
        console.log("[changeStrategy] changeStrategy end");
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Callback ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function lockAcquired(
        bytes calldata rawData
    ) external override vaultOnly returns (bytes memory) {
        console.log("[lockAcquired] lockAcquired start");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        console.log("[lockAcquired] data.currency", data.currency);
        console.log("[lockAcquired] data.sender", data.sender);
        console.log("[lockAcquired] data.depositAmount", data.depositAmount);
        console.log("[lockAcquired] data.withdrawAmount", data.withdrawAmount);
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
        console.log("[lockAcquired] lockAcquired end");
        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _payRent(
        PoolKey memory key
    ) internal returns (AuctionSlot0 slot0) {
        console.log("[_payRent] _payRent start");
        slot0 = poolSlot0[key.toId()];
        AuctionSlot1 slot1 = poolSlot1[key.toId()];
        console.log("[_payRent] block number", block.number);
        console.log("[_payRent] rentData.lastPaidBlock", slot1.lastPaidBlock());
        console.log("[_payRent] rentData.rentEndBlock", slot1.rentEndBlock());
        console.log("[_payRent] hookState.strategy", slot0.strategyAddress());
        console.log("[_payRent] hookState.rentPerBlock", slot1.rentPerBlock());
        console.log("[_payRent] Remaining rent", slot1.remainingRent());

        uint32 lastPaidBlock = slot1.lastPaidBlock();
        uint120 remainingRent = slot1.remainingRent();

        if (lastPaidBlock == uint32(block.number) || remainingRent == 0) {
            console.log("[_payRent] rentData.lastPaidBlock == block.number");
            return slot0;
        }

        // check if we need to change strategy
        if (slot1.shouldChangeStrategy()) {
            console.log("[_payRent] rentData.shouldChangeStrategy");
            slot0.setStrategyAddress(winnerStrategies[key.toId()]);
            slot1.setShouldChangeStrategy(false);
            poolSlot0[key.toId()] = slot0;
            console.log(
                "[_payRent] Strategy changed to",
                slot0.strategyAddress()
            );
        }

        uint32 blocksElapsed;
        unchecked {
            blocksElapsed = uint32(block.number) - lastPaidBlock;
        }

        // overflow unlikely to happen, rentPerBlock is capped at 2^96
        // for overflow to happen 2^128 / rentPerBlock > 2^24 = 194 days
        uint120 rentAmount = uint120(slot1.rentPerBlock() * blocksElapsed);

        if (rentAmount > remainingRent) {
            rentAmount = remainingRent;
            winners[key.toId()] = address(0);
            winnerStrategies[key.toId()] = address(0);
            slot1.setShouldChangeStrategy(true);
            slot1.setRentPerBlock(0);
        }
        console.log(
            "[_payRent] Rent period ended, resetting winner and strategy"
        );

        slot1.setLastPaidBlock(uint32(block.number));

        unchecked {
            slot1.setRemainingRent(remainingRent - rentAmount);
        }

        // pay the rent
        Currency currency = _getPoolRentCurrency(key);

        vault.burn(address(this), currency, rentAmount);
        poolManager.donate(key, rentAmount, 0, "");

        console.log("[_payRent] blocksElapsed", blocksElapsed);
        console.log("[_payRent] rentAmount", rentAmount);
        console.log(
            "[_payRent] Paying rentAmount",
            rentAmount,
            "in currency",
            Currency.unwrap(currency)
        );

        poolSlot1[key.toId()] = slot1;

        console.log("[_payRent] Remaining rent after", slot1.remainingRent());

        console.log("[_payRent] _payRent end");
        return slot0;
    }
}
