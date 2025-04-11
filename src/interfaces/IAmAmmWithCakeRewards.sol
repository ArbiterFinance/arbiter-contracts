// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IArbiterAmAmmHarbergerLease} from "./IArbiterAmAmmHarbergerLease.sol";
import {IRewardTracker} from "./IRewardTracker.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @title amAMM With Cake Rewards Interface
/// @notice This interface combines the Harberger Lease and Reward Tracker hooks
/// to allow for bidding and distributing rewards to any pool with any ERC20 token.
/// @notice To be eligible for rewards, users must subscrbe to the pool IRewardTracker::INotifier.
/// @notice IRewardTracker is used to track the reward per second of subscribed reward within pools like in V3.
/// @notice The rewards are distributed to the subscribers based on the reward per second of the subscribed reward.
interface IAmAmmWithCakeRewards is IArbiterAmAmmHarbergerLease, IRewardTracker {
    /// @notice Collects the rewards for the pool for the msg.sender
    /// @param key The key of the pool to collect rewards from
    function collectRewards(PoolKey calldata key) external;
}
