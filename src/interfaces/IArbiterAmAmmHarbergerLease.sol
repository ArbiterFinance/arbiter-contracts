// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";

/// @title Arbiter AmAmm Harberger Lease
/// @notice Interface for an auction system based on Harberger Tax principles.
/// @notice The auctioned assets are the rights to control and collect swap fees from V4 liquidity pools.
/// @dev strategy SHOULD implement IArbiterAmAmmStrategy
interface IArbiterAmAmmHarbergerLease {
    error NotDynamicFee();
    error RentTooLow();
    error RentTooShort();
    error PoolNotInitialized();
    error InsufficientDeposit();
    error CallerNotWinner();
    error InvalidWinnerFeeShare();

    event Deposit(
        address indexed account,
        address indexed asset,
        uint256 amount
    );
    event Withdraw(
        address indexed account,
        address indexed asset,
        uint256 amount
    );
    event Overbid(
        address indexed winner,
        PoolId indexed id,
        uint80 rentPerBlock,
        uint32 rentEndBlock,
        address strategy
    );
    event ChangeStrategy(PoolId indexed id, address strategy);

    /// @return  The minimum time in blocks that an overbidding rent must last
    function minimumRentBlocks(
        PoolKey calldata key
    ) external view returns (uint64);

    /// @return The required factor by which an overbidding rent must exceed the current rent, unless the current rent finishes in fewer than TRANSITION_BLOCKS.
    function rentFactor(PoolKey calldata key) external view returns (uint32);

    /// @return The number of blocks before the end of the rent when any bid is overbidding the current rent
    function transitionBlocks(
        PoolKey calldata key
    ) external view returns (uint64);

    /// @return The gas limit for the getSwapFee call
    function getFeeGasLimit(
        PoolKey calldata key
    ) external view returns (uint256);

    /// @return The percentage of the swap fee that will be paid to the winner
    function winnerFeeShare(
        PoolKey calldata key
    ) external view returns (uint24);

    /// @return The deposit of the account for the asset
    /// @param asset The address of the ERC20 to check
    /// @param account The address of the account to check
    function depositOf(
        address asset,
        address account
    ) external view returns (uint256);

    /// @return The address of ERC20 that is used for bidding in the pool
    /// @param key The key of the pool to check
    function biddingCurrency(
        PoolKey calldata key
    ) external view returns (address);

    /// @return The address of the active Strategy for the pool
    /// @param key The key of the pool to check
    function activeStrategy(
        PoolKey calldata key
    ) external view returns (address);

    /// @dev If the winnerStrategy is different from the activeStrategy, then the active strategy will be changed for the winner strategy during next rent payment
    /// @return The address of the winning Strategy for the pool
    /// @param key The key of the pool to check
    function winnerStrategy(
        PoolKey calldata key
    ) external view returns (address);

    /// @return The address of the winner of the pool
    /// @param key The key of the pool to check
    function winner(PoolKey calldata key) external view returns (address);

    /// @return The rent per block for the pool in the pool's bidding currency
    /// @param key The key of the pool to check
    function currentRentPerBlock(
        PoolKey calldata key
    ) external view returns (uint96);

    /// @return The block number of the last rent payment
    /// @param key The key of the pool to check
    function currentRentEndBlock(
        PoolKey calldata key
    ) external view returns (uint32);

    /// @notice Transfers ERC20 from msg.sender into this contract to be later used by msg.sender for bidding
    /// @param asset The address of the ERC20 to deposit
    /// @param amount The amount of the ERC20 to deposit
    function deposit(address asset, uint256 amount) external;

    /// @notice Overbids the current rent for the pool - rentPerBlock * (rentEndBlock - block.number) are subtracted from the msg.sender deposit
    /// @notice If there is a previous winning bid, the rent is refunded to the deposit
    /// @dev The rent must be higher than the current rent by RENT_FACTOR unless the current rent finishes in less than transition_blocks
    /// @dev The rentEndBlock must be at least minimumRentTimeInBlocks in the future
    /// @dev The sender must have enough deposit to cover the rent
    /// @param key The key of the pool to overbid
    /// @param rentPerBlock The new rent per block
    /// @param rentEndBlock The new rent end block
    /// @param strategy The address of the strategy that will be used if the bid wins from the next rent payment
    function overbid(
        PoolKey calldata key,
        uint80 rentPerBlock,
        uint32 rentEndBlock,
        address strategy
    ) external;

    /// @notice Withdraws deposited ERC20 from this contract
    /// @param asset The address of the ERC20 to withdraw
    /// @param amount The amount of the ERC20 to withdraw
    function withdraw(address asset, uint256 amount) external;

    /// @notice Changes the strategy for the pool
    /// @dev The sender must be the current winner
    /// @param key The key of the pool to change the strategy for
    /// @param strategy The address of the new strategy
    function changeStrategy(PoolKey calldata key, address strategy) external;
}
