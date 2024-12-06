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

/// @notice ArbiterAmAmmBaseHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The strategy address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The strategy address should be able to manage ERC6909 claim tokens in the PoolManager.
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

    uint32 internal _transitionBlocks = 30;
    uint32 internal _minRentBlocks = 300;
    uint24 internal _overbidFactor = 2e4; // 2%
    uint24 internal _defaultAuctionFee = 0;
    uint24 internal _defaultWinnerFeeShare = 5e4;
    uint8 internal _defaultStrategyGasLimit = 13;
    uint16 internal _defaultSwapFee = 4e2; // 0.04%

    mapping(PoolId => AuctionSlot0) public poolSlot0;
    mapping(PoolId => AuctionSlot1) public poolSlot1;
    mapping(PoolId => address) public winners;
    mapping(PoolId => address) public winnerStrategies;
    mapping(address => mapping(Currency => uint256)) public deposits;
    mapping(PoolId => AuctionFee) public auctionFees;

    struct AuctionFee {
        uint128 initialRemainingRent;
        uint128 feeLocked;
        uint128 collectedFee;
    }

    constructor(
        ICLPoolManager _poolManager,
        address _initOwner
    ) CLBaseHook(_poolManager) Ownable(_initOwner) {}

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHooksRegistrationBitmap()
        external
        pure
        virtual
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

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not initialized with dynamic fees.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external virtual override poolManagerOnly returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicLPFee()) revert NotDynamicFee();
        PoolId poolId = key.toId();

        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        poolSlot0[poolId] = AuctionSlot0
            .wrap(bytes32(0))
            .setWinnerFeeSharePart(_defaultWinnerFeeShare)
            .setStrategyGasLimit(_defaultStrategyGasLimit)
            .setDefaultSwapFee(_defaultSwapFee)
            .setAuctionFee(_defaultAuctionFee)
            .setLastActiveTick(tick);

        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override poolManagerOnly returns (bytes4) {
        _payRentAndChangeStrategyIfNeeded(key);
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
        virtual
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        console.log("[beforeSwap] start");
        console.log("[beforeSwap] block.number: %d", block.number);
        PoolId poolId = key.toId();
        AuctionSlot0 slot0 = poolSlot0[poolId];
        slot0 = _changeStrategyIfNeeded(slot0, poolId);
        poolSlot0[poolId] = slot0;
        address strategy = slot0.strategyAddress();
        uint24 fee = slot0.defaultSwapFee();
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
            IArbiterFeeProvider(strategy).getSwapFee{
                gas: 2 << slot0.strategyGasLimit()
            }(sender, key, params, hookData)
        returns (uint24 _fee) {
            console.log("[beforeSwap] _fee: %d", _fee);
            if (_fee <= 1e6) {
                fee = _fee;
            }
        } catch {}
        console.log("[beforeSwap] fee: %d", fee);

        int256 totalFees = (params.amountSpecified * int256(uint256(fee))) /
            1e6;
        console.log("[beforeSwap] totalFees: %d", totalFees);
        uint256 absTotalFees = totalFees < 0
            ? uint256(-totalFees)
            : uint256(totalFees);
        console.log("[beforeSwap] absTotalFees: %d", absTotalFees);

        // Calculate fee split
        uint256 strategyFee = (absTotalFees * slot0.winnerFeeSharePart()) / 1e6;

        console.log("[beforeSwap] strategyFee: %d", strategyFee);
        uint256 lpFee = absTotalFees - strategyFee;
        console.log("[beforeSwap] lpFee: %d", lpFee);

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;

        bool isFeeCurrency0 = exactOut == params.zeroForOne;

        if (exactOut == params.zeroForOne) {
            console.log("[beforeSwap] feeCurrency key.currency0");
        } else {
            console.log("[beforeSwap] feeCurrency key.currency1");
        }

        if (exactOut) {
            console.log("[beforeSwap] exactOut");
        } else {
            console.log("[beforeSwap] exactIn");
        }

        // Send fees to strategy
        vault.mint(
            strategy,
            isFeeCurrency0 ? key.currency0 : key.currency1,
            strategyFee
        );

        if (isFeeCurrency0) {
            console.log("[beforeSwap] donate amount0");
            poolManager.donate(key, lpFee, 0, "");
        } else {
            console.log("[beforeSwap] donate amount1");
            poolManager.donate(key, 0, lpFee, "");
        }

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
    ) external virtual override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        AuctionSlot0 slot0 = poolSlot0[poolId];
        if (tick != slot0.lastActiveTick()) {
            console.log("[afterSwap] tick != slot0.lastActiveTick()");
            _payRentAndChangeStrategyIfNeeded(key);
        }

        return (this.afterSwap.selector, 0);
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
        return poolSlot0[key.toId()].strategyGasLimit();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function winnerFeeShare(
        PoolKey calldata key
    ) external view returns (uint24) {
        return poolSlot0[key.toId()].winnerFeeSharePart();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function depositOf(
        address asset,
        address account
    ) external view override returns (uint256) {
        return deposits[account][Currency.wrap(asset)];
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function biddingCurrency(
        PoolKey calldata key
    ) external view override returns (address) {
        return Currency.unwrap(_getPoolRentCurrency(key));
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function activeStrategy(
        PoolKey calldata key
    ) external view override returns (address) {
        return poolSlot0[key.toId()].strategyAddress();
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
    function currentRentPerBlock(
        PoolKey calldata key
    ) external view override returns (uint96) {
        return poolSlot1[key.toId()].rentPerBlock();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function currentRentEndBlock(
        PoolKey calldata key
    ) public view override returns (uint32) {
        return poolSlot1[key.toId()].rentEndBlock();
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function deposit(address asset, uint256 amount) external override {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        vault.lock(abi.encode(CallbackData(asset, msg.sender, amount, 0)));
        deposits[msg.sender][Currency.wrap(asset)] += amount;

        emit Deposit(msg.sender, asset, amount);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function overbid(
        PoolKey calldata key,
        uint80 rentPerBlock,
        uint32 rentEndBlock,
        address strategy
    ) external {
        PoolId poolId = key.toId();
        (uint160 price, , , ) = poolManager.getSlot0(poolId);
        if (price == 0) {
            revert PoolNotInitialized();
        }

        AuctionSlot0 slot0 = poolSlot0[poolId];
        AuctionSlot1 slot1 = poolSlot1[poolId];

        unchecked {
            uint32 minimumEndBlock = uint32(block.number) + _minRentBlocks;
            require(
                rentEndBlock >= minimumEndBlock ||
                    rentEndBlock < uint32(block.number),
                RentTooShort()
            );
        }

        uint64 _currentRentEndBlock = slot1.rentEndBlock();

        unchecked {
            if (
                uint256(uint32(block.number)) + _transitionBlocks <
                _currentRentEndBlock
            ) {
                uint120 minimumRentPerBlock = uint120(slot1.rentPerBlock()) +
                    (uint120(slot1.rentPerBlock()) * _overbidFactor) /
                    1e6;
                if (uint120(rentPerBlock) <= minimumRentPerBlock) {
                    revert RentTooLow();
                }
            }
        }

        _payRentAndChangeStrategyIfNeeded(key);

        Currency currency = _getPoolRentCurrency(key);

        // refund the remaining rentPerBlock to the previous winner
        uint128 remainingRent = slot1.remainingRent();
        if (remainingRent > 0) {
            AuctionFee memory prevAuctionFee = auctionFees[poolId];

            uint128 feeRefund = uint128(
                (uint256(prevAuctionFee.feeLocked) * remainingRent) /
                    prevAuctionFee.initialRemainingRent
            );
            uint128 collectedFee = prevAuctionFee.feeLocked - feeRefund;

            deposits[winners[poolId]][currency] +=
                slot1.remainingRent() +
                feeRefund;
            auctionFees[poolId] = AuctionFee(0, 0, collectedFee);
        }

        // charge the new winner
        uint64 rentBlockLength = rentEndBlock - uint64(block.number);
        uint128 totalRent = rentPerBlock * rentBlockLength;
        uint128 auctionFee = (totalRent * slot0.auctionFee()) / 1e6;
        uint128 requiredDeposit = totalRent + auctionFee;
        unchecked {
            uint256 availableDeposit = deposits[msg.sender][currency];

            if (availableDeposit < requiredDeposit) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][currency] = availableDeposit - requiredDeposit;
        }

        // set up new rent

        poolSlot0[poolId] = slot0.setShouldChangeStrategy(true);
        poolSlot1[poolId] = slot1
            .setRemainingRent(totalRent)
            .setLastPaidBlock(uint32(block.number))
            .setRentPerBlock(rentPerBlock);

        auctionFees[poolId].initialRemainingRent = totalRent;
        auctionFees[poolId].feeLocked = auctionFee;

        winners[poolId] = msg.sender;
        winnerStrategies[poolId] = strategy;

        emit Overbid(msg.sender, poolId, rentPerBlock, rentEndBlock, strategy);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function withdraw(address asset, uint256 amount) external override {
        uint256 depositAmount = deposits[msg.sender][Currency.wrap(asset)];
        unchecked {
            if (depositAmount < amount) {
                revert InsufficientDeposit();
            }
            deposits[msg.sender][Currency.wrap(asset)] = depositAmount - amount;
        }
        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        vault.lock(abi.encode(CallbackData(asset, msg.sender, 0, amount)));

        emit Withdraw(msg.sender, asset, amount);
    }

    /// @inheritdoc IArbiterAmAmmHarbergerLease
    function changeStrategy(
        PoolKey calldata key,
        address strategy
    ) external override {
        PoolId poolId = key.toId();
        if (
            msg.sender != winners[poolId] ||
            poolSlot1[key.toId()].remainingRent() == 0
        ) {
            revert CallerNotWinner();
        }
        winnerStrategies[poolId] = strategy;
        poolSlot0[poolId].setShouldChangeStrategy(true);

        emit ChangeStrategy(msg.sender, poolId, strategy);
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

        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _changeStrategyIfNeeded(
        AuctionSlot0 slot0,
        PoolId poolId
    ) internal view returns (AuctionSlot0) {
        // check if we need to change strategy
        if (slot0.shouldChangeStrategy()) {
            console.log("[_changeStrategyIfNeeded] shouldChangeStrategy");
            slot0 = slot0
                .setStrategyAddress(winnerStrategies[poolId])
                .setShouldChangeStrategy(false);
        }

        return slot0;
    }

    function _payRentAndChangeStrategyIfNeeded(PoolKey memory key) internal {
        PoolId poolId = key.toId();
        AuctionSlot1 slot1 = poolSlot1[poolId];

        uint32 lastPaidBlock = slot1.lastPaidBlock();
        uint128 remainingRent = slot1.remainingRent();

        console.log(
            "[_payRentAndChangeStrategyIfNeeded] lastPaidBlock: %d",
            lastPaidBlock
        );
        console.log(
            "[_payRentAndChangeStrategyIfNeeded] remainingRent: %d",
            remainingRent
        );
        console.log(
            "[_payRentAndChangeStrategyIfNeeded] block.number: %d",
            block.number
        );
        if (lastPaidBlock == uint32(block.number)) {
            console.log(
                "[_payRentAndChangeStrategyIfNeeded] lastPaidBlock == block.number"
            );
            return;
        }

        if (remainingRent == 0) {
            console.log(
                "[_payRentAndChangeStrategyIfNeeded] remainingRent == 0"
            );
            slot1 = slot1.setLastPaidBlock(uint32(block.number));
            poolSlot1[poolId] = slot1;
            return;
        }
        AuctionSlot0 slot0 = poolSlot0[poolId];
        slot0 = _changeStrategyIfNeeded(slot0, poolId);

        uint32 blocksElapsed;
        unchecked {
            blocksElapsed = uint32(block.number) - lastPaidBlock;
        }

        console.log(
            "[_payRentAndChangeStrategyIfNeeded] blocksElapsed: %d",
            blocksElapsed
        );
        console.log(
            "[_payRentAndChangeStrategyIfNeeded] rentPerBlock: %d",
            slot1.rentPerBlock()
        );

        uint128 rentAmount = slot1.rentPerBlock() * blocksElapsed;

        console.log(
            "[_payRentAndChangeStrategyIfNeeded] rentAmount: %d",
            rentAmount
        );
        if (rentAmount > remainingRent) {
            // pay the remainingRent and reset the auction - no winner
            rentAmount = remainingRent;
            winners[poolId] = address(0);
            winnerStrategies[poolId] = address(0);
            slot0 = slot0.setShouldChangeStrategy(true);
            slot1 = slot1.setRentPerBlock(0);
        }

        slot1 = slot1.setLastPaidBlock(uint32(block.number));

        unchecked {
            slot1 = slot1.setRemainingRent(remainingRent - rentAmount);
        }

        _distributeRent(key, rentAmount);

        poolSlot1[poolId] = slot1;
        poolSlot0[poolId] = slot0;

        return;
    }

    function _distributeRent(
        PoolKey memory key,
        uint128 rentAmount
    ) internal virtual;

    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view virtual returns (Currency);

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////// only Owner ///////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function setTransitionBlocks(uint32 transitionBlocks_) external onlyOwner {
        _transitionBlocks = transitionBlocks_;
    }

    function setMinRentBlocks(uint32 minRentBlocks_) external onlyOwner {
        _minRentBlocks = minRentBlocks_;
    }

    function setOverbidFactor(uint24 overbidFactor_) external onlyOwner {
        _overbidFactor = overbidFactor_;
    }

    function setWinnerFeeSharePart(
        PoolKey calldata key,
        uint24 winnerFeeSharePart
    ) external onlyOwner {
        poolSlot0[key.toId()] = poolSlot0[key.toId()].setWinnerFeeSharePart(
            winnerFeeSharePart
        );
    }

    function setStrategyGasLimit(
        PoolKey calldata key,
        uint8 strategyGasLimit
    ) external onlyOwner {
        poolSlot0[key.toId()] = poolSlot0[key.toId()].setStrategyGasLimit(
            strategyGasLimit
        );
    }

    function setDefaultSwapFee(
        PoolKey calldata key,
        uint16 defaultSwapFee
    ) external onlyOwner {
        poolSlot0[key.toId()] = poolSlot0[key.toId()].setDefaultSwapFee(
            defaultSwapFee
        );
    }

    function setAuctionFee(
        PoolKey calldata key,
        uint24 auctionFee
    ) external onlyOwner {
        poolSlot0[key.toId()] = poolSlot0[key.toId()].setAuctionFee(auctionFee);
    }

    function collectAuctionFees(
        PoolKey calldata key,
        address to
    ) external onlyOwner {
        PoolId poolId = key.toId();
        uint128 collectedFee = auctionFees[poolId].collectedFee;
        auctionFees[poolId].collectedFee = 0;

        vault.lock(
            abi.encode(
                CallbackData(
                    Currency.unwrap(_getPoolRentCurrency(key)),
                    to,
                    0,
                    collectedFee
                )
            )
        );
    }
}
