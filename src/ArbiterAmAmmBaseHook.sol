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

// TODO decide on the blockNumber storage size uint32 / uint48 / uint64

uint8 constant DEFAULT_WINNER_FEE_SHARE = 6; // 6/127 ~= 4.72%
uint8 constant DEFAULT_GET_SWAP_FEE_LOG = 13; // 2^13 = 8192
uint24 constant DEFAULT_MAX_POOL_SWAP_FEE = 10000; // 1.0%
uint16 constant DEFAULT_DEFAULT_POOL_SWAP_FEE = 300; // 0.03%

uint24 constant DEFAULT_FEE = 400; // 0.04%

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
abstract contract ArbiterAmAmmBaseHook is
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

    uint32 internal _transitionBlocks;
    uint32 internal _minRentBlocks;
    uint32 internal _overbidFactor;

    mapping(PoolId => AuctionSlot0) public poolSlot0;
    mapping(PoolId => AuctionSlot1) public poolSlot1;
    mapping(PoolId => address) public winners;
    mapping(PoolId => address) public winnerStrategies;
    mapping(address => mapping(Currency => uint256)) public deposits;

    constructor(
        ICLPoolManager _poolManager,
        address _initOwner,
        uint32 transitionBlocks_,
        uint32 minRentBlocks_,
        uint32 overbidFactor_
    ) CLBaseHook(_poolManager) Ownable(_initOwner) {
        console.log("[Constructor] Constructor start");

        _transitionBlocks = transitionBlocks_;
        _minRentBlocks = minRentBlocks_;
        _overbidFactor = overbidFactor_;
        console.log("[Constructor] Constructor end");
    }

    ///////////////////////////////////////////////////////////////////////////////////
    /////////////////////////// IArbiterAmAmmHarbergerLease ///////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function minimumRentBlocks(
        PoolKey calldata
    ) external view returns (uint64) {
        return _minRentBlocks;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function rentFactor(PoolKey calldata) external view returns (uint32) {
        return _overbidFactor;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function transitionBlocks(PoolKey calldata) external view returns (uint64) {
        return _transitionBlocks;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function getFeeGasLimit(
        PoolKey calldata key
    ) external view returns (uint256) {
        return poolSlot1[key.toId()].strategyGasLimit();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerFeeShare(
        PoolKey calldata key
    ) external view returns (uint16) {
        return poolSlot1[key.toId()].winnerFeeSharePart();
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
        uint96 rent = poolSlot0[key.toId()].rentPerBlock();
        console.log("[rentPerBlock] rentPerBlock end");
        return rent;
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function currentRentEndBlock(
        PoolKey calldata key
    ) public view override returns (uint48) {
        console.log("[rentEndBlock] rentEndBlock start");
        uint64 endBlock = poolSlot0[key.toId()].rentEndBlock(
            poolSlot1[key.toId()]
        );
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

        uint64 minimumEndBlock = uint64(block.number) + _minRentBlocks;
        if (rentEndBlock < minimumEndBlock) {
            revert RentTooShort();
        }

        uint64 _currentRentEndBlock = slot0.rentEndBlock(slot1);
        console.log("[overbid] _currentRentEndBlock", _currentRentEndBlock);
        console.log("[overbid] block.number", block.number);
        console.log("[overbid] transitionBlocks", _transitionBlocks);
        if (
            _currentRentEndBlock == 0 ||
            // _currentRentEndBlock < slot0
            block.number < _currentRentEndBlock - _transitionBlocks
        ) {
            console.log("[overbid] overbidFactor", _overbidFactor);
            console.log("[overbid] rentPerBlock", slot0.rentPerBlock());
            uint96 minimumRentPerBlock = uint96(
                (slot0.rentPerBlock() * _overbidFactor) / 127
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
            console.log("[overbid] requiredDeposit", requiredDeposit);
            uint256 availableDeposit = deposits[msg.sender][currency];
            console.log("[overbid] availableDeposit", availableDeposit);
            if (availableDeposit < requiredDeposit) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][currency] = availableDeposit - requiredDeposit;
        }

        // set up new rent

        poolSlot0[key.toId()] = slot0
            .setStrategyAddress(strategy)
            .setRentPerBlock(rentPerBlock);
        poolSlot1[key.toId()] = slot1
            .setLastPaidBlock(uint32(block.number))
            .setRemainingRent(requiredDeposit)
            .setShouldChangeStrategy(true);
        console.log("[overbid] rent per block", slot0.rentEndBlock(slot1));
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
            currentRentEndBlock(key) <= block.number
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
    ) internal virtual returns (AuctionSlot0 slot0);

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view virtual returns (Currency);
}
