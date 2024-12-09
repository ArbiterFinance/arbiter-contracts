# Arbiter am-AMM

## Auction Managed AMM implementation

### Description

The Auction Managed AMM (am-AMM) introduces a Harberger lease-based auction mechanism into PancakeSwap v4 pools, inspired by Austin Adam's paper [link](https://arxiv.org/abs/2403.03367). Participants can bid for the right to control pool's swap fee by continuously outbidding each other.

Key aspects of the am-AMM implementation:

- **Harberger Lease Auction:** Control rights are continuously auctioned. The highest bidder gains control for a certain period but can be challenged at any time by a higher bid.
- **Dynamic Fee Adjustments:** The winner can supply a custom strategy to determine the swap fee rate dynamically. This creates a market-based solution to the optimal fee problem.
- **MEV Redirection:** Auction proceeds effectively get redirected to the pool, capturing the value of MEV for LPs.
- **Acutions Run In Pool Currencies or Any ERC20 Token:** The auction can be run in any ERC20 token or one of the pool's tokens.
- **Additional CAKE Token Utility** Increase CAKE token utility by running
  am-AMM auctions in CAKE token.

## Active Tick Incentives in Any Currency

### Description

The `RewardTracker` is a composable & efficient solution to track and
distribute incentives for in-range Liquidity that can be combined with any hook.

- **Any ERC20 Token:** Incentive payouts can be in any token, enabling novel incentive structures. For example, distributing governance tokens, stablecoins, or even exotic assets as rewards.
- **In-Range Liquidity Rewards:** Only liquidity that falls into the active price range when swaps occur earns proportional rewards.
- **Time-Varying Incentives:** Rewards can be adjusted over time as desired, allowing for dynamic incentive schemes and experimentation.

## Features

1. **Auction Managed AMM (am-AMM):**  
   Implements a Harberger lease-based auction system that lets users "bid" in any token for the right to control specific aspects of the pool. The highest bidder (winner) can:

   - Control the dynamic fee structure via a customizable strategy.
   - Earn a share of the swap fees.
   - Donate or distribute incentives to in-range LPs seamlessly.
   - Allows hook owner to charge fee on distributed rent
   - Allows hook owner to control parameters like:
     - maximal gas cost of swap fee calculation
     - auction fee
     - swap fee share that goes to the winer

2. **Abstract Reward Tracker:**  
   A mechanism to track and distribute rewards to active liquidity providers. It can:
   - Distribute any ERC20 token as rewards for in-range liquidity.
   - Support multiple sources of rewards over time.
   - Operate through an `ISubscriber` interface.
   - Gas efficient & composable design.
   - Integrate with any hook to reward in range LPs.

- **Time-Varying Incentives:** Easily adjust incentive levels over time without changing pool contracts.
- **Any-Token Rewards:** Distribute rewards in any ERC20 token (e.g., CAKE or other tokens).
- **Active Range Incentivization:** Reward LPs only when their liquidity is actively used by swaps in the range.
- **Harberger Lease Auction:** Continuously auction off the "right" to influence pool parameters and capture MEV.
- **Dynamic Fees:** The winning bidder can adjust fee strategies to find the optimal fee for the pool.
- **Gas-Efficient**: Uses packed storage slots & optimizes reads/writes for minimal overhead
- **Composable Design:**: Both `RewardTracker` and `ArbiterAmAmmBaseHook` are focused on maximizing flexibility & allow for easy usage/integration.

## Folder Structure

```
.
├── foundry.toml
├── LICENSE
├── README.md
├── remappings.txt
├── run_tests.sh
├── src
│   ├── ArbiterAmAmmAnyERC20Hook.sol
│   ├── ArbiterAmAmmBaseHook.sol
│   ├── ArbiterAmAmmPoolCurrencyHook.sol
│   ├── interfaces
│   │   ├── IAmAmmWithERC20Rewards.sol
│   │   ├── IArbiterAmAmmHarbergerLease.sol
│   │   ├── IArbiterAmmStrategy.sol
│   │   ├── IArbiterFeeProvider.sol
│   │   ├── IPoolKeys.sol
│   │   └── IRewardTracker.sol
│   ├── libraries
│   │   ├── PoolExtension.sol
│   │   └── PositionExtension.sol
│   ├── RewardTracker.sol
│   └── types
│       ├── AuctionSlot0.sol
│       └── AuctionSlot1.sol
└── test
    ├── ArbiterAmAmmAnyERC20Hook.t.sol
    ├── ArbiterAmAmmPoolCurrencyHook.t.sol
    ├── contracts
    │   └── NoOpRewardTracker.sol
    └── RewardTracker.t.sol
```

**Key Components:**

- `ArbiterAmAmmBaseHook.sol`: Abstract base contract for the auction-managed AMM, handling rent payment logic and integration with the reward tracker.
- `ArbiterAmAmmAnyERC20Hook.sol`: Concrete implementation supporting arbitrary ERC20 tokens for rent and reward distribution.
- `ArbiterAmAmmPoolCurrencyHook.sol`: Variant that uses one of the pool's tokens as the rent/reward currency.
- `RewardTracker.sol`: Abstract contract implementing reward tracking logic, intended to be inherited and integrated with the PancakeSwap v4 hooks.

## Interfaces

### IAmAmmWithERC20Rewards

Combines Harberger Lease and Rewards-Per-Second tracking to distribute ERC20 rewards to active liquidity ranges.

### IArbiterAmAmmHarbergerLease

Defines the methods related to the Harberger lease-based auction system, including depositing, bidding, overbidding, and withdrawing tokens.

### IArbiterAmmStrategy

Allows controlling the fee calculation logic. The auction winner can provide a custom strategy to dynamically adjust the swap fee - implementing `IArbiterAmmStrategy` interface.

### IArbiterFeeProvider

Used by the AMM to get the current swap fee from auction winner. The call gas cost is limited by hook's parameter.

### IRewardTracker

Specifies the methods needed to track and distribute rewards to active liquidity. This is at the heart of incentivizing LPs over time.

## How to Use the Abstract Reward Tracker

The `RewardTracker` is an abstract contract designed to be integrated into your hook contracts that wish to:

- Track in-range liquidity.
- Distribute ERC20 rewards.
- Automatically adjust incentives as the pool parameters change.

Key points:

- **ISubscriber Interface:**  
  The `RewardTracker` relies on the `ISubscriber` interface from PancakeSwap v4 Periphery. To track LPs rewards LPs need to subscribe their position to the contract using `RewardRracker`. Once subscribed whenever a position is modified or unsubscribed, it triggers notifications and allows the `RewardTracker` to update the accrued rewards for the LPs.
- **Claiming rewards:**  
  While the rewards get calculated automatically, LPs need to claim their rewards that are available in the `accruedRewards` mapping (a mapping from rewards owner to the accrued rewards amount). The mapping is available for a hook that integrates `RewardTracker` which needs only to implement simple method to allow LPs to claim their rewards. Example:

```solidity
function collectRewards(address to) external returns (uint256 rewards) {
    rewards = accruedRewards[msg.sender];
    accruedRewards[msg.sender] = 0;

    // assumes rewardCurrrency is an address
    poolManager.unlock(abi.encode(rewardCurrency, to, 0, rewards)));
```

- **Integrating the Reward Tracker:**

  1. **Initialization (`_initialize`)**:  
     Call `_initialize(poolId, activeTick)` when a pool is set up to start tracking rewards.

  2. **Distributing Rewards (`_distributeRewards`)**:  
     Call `_distributeReward(poolId, rewardAmount)` whenever new rewards need to be distributed to the active range. This updates internal state so that currently active LPs will receive the correct shares.

  3. **Updating on Active Tick Changes (`_handleActiveTickChange`)**:  
     If the active tick changes (e.g., after a swap), call `_handleActiveTickChange` to update internal tracking logic and ensure rewards remain accurate.

  4. **Accruing Rewards (`_accrueRewards`)**:  
     Internally called whenever liquidity changes, this function ensures that LPs receive the correct share of rewards when they modify their positions, subscribe, or unsubscribe.

- **Before Notifications Hooks:**
  The `RewardTracker` defines several `_beforeOnXxxTracker` methods that you can override to perform actions before internal reward logic executes. For example:

  - `_beforeOnSubscribeTracker(poolKey)`
  - `_beforeOnUnubscribeTracker(poolKey)`
  - `_beforeOnBurnTracker(poolKey)`
  - `_beforeOnModifyLiquidityTracker(poolKey)`

  In the provided implementation, the AMM uses these hooks to ensure rent is paid and strategy changes are applied before updating the reward distribution.

## Example usage with ArbiterAmAmmBaseHook

`ArbiterAmAmmAnyERC20Hook` is an abstract contract that ties together:

- The Harberger lease auction logic (ArbiterAmAmmBaseHook)
- The Reward Tracker.

1. **`_getPoolRentCurrency`**:  
   Used to pecify which currency is used for the rent (eg: any ERC20 token or a pool token).

2. **`_distributeRent`**:  
   Defines how rent is distributed. Updates the reward tracking logic with the rent amount. In `ArbiterAmAmmPoolCurrencyHook`, it burns the tokens and donates them to the pool using `_donate` method.

3. **Handled Active Tick Changes**:  
   In the `afterSwap` hook, as well as any `_onBefore` RewardTracker's action, the `_payRentAndChangeStrategyIfNeeded` is called and `_handleActiveTickChange` is performed to ensure the reward distribution remains accurate as market conditions shift.

4. **Bidding and Overbidding**:  
   Users can deposit tokens and call `overbid` to become the winner. The contract updates the current winner, the rent rate, and collects rent periodically.
