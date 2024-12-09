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
- **Time-Varying Incentives:** Rewards can be adjusted over time.

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
