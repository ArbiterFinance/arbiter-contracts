// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLHooks} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
import {LiquidityAmounts} from "pancake-v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {RewardTracker} from "../src/RewardTracker.sol";
import {PoolExtension} from "../src/libraries/PoolExtension.sol";
import {PositionExtension} from "../src/libraries/PositionExtension.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbiterAmAmmAnyERC20Hook} from "../src/ArbiterAmAmmAnyERC20Hook.sol";
import {CLTestUtils} from "./pool-cl/utils/CLTestUtils.sol";
import {MockCLSwapRouter} from "./pool-cl/helpers/MockCLSwapRouter.sol";
import {IArbiterFeeProvider} from "../src/interfaces/IArbiterFeeProvider.sol";
import {AuctionSlot0, AuctionSlot0Library} from "../src/types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "../src/types/AuctionSlot1.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {AuctionSlot0, AuctionSlot0Library} from "../src/types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "../src/types/AuctionSlot1.sol";

contract MockStrategy is IArbiterFeeProvider {
    uint24 public fee;

    constructor(uint24 _fee) {
        fee = _fee;
    }

    function getSwapFee(
        address,
        PoolKey calldata,
        ICLPoolManager.SwapParams calldata,
        bytes calldata
    ) external view returns (uint24) {
        return fee;
    }

    function setFee(uint24 _fee) external {
        fee = _fee;
    }
}

contract ArbiterAmAmmAnyERC20HookTest is Test, CLTestUtils {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;
    using AuctionSlot0Library for AuctionSlot0;
    using AuctionSlot1Library for AuctionSlot1;

    MockERC20 token0;
    MockERC20 token1;
    Currency rentCurrency;
    Currency currency0;
    Currency currency1;
    MockCLSwapRouter swapRouter;

    PoolId poolId;
    PoolKey key;

    uint256 constant STARTING_BLOCK = 10_000_000;
    uint256 CURRENT_BLOCK_NUMBER = STARTING_BLOCK;

    uint24 constant DEFAULT_SWAP_FEE = 300;
    uint32 constant DEFAULT_MINIMUM_RENT_BLOCKS = 300;
    uint24 constant DEFAULT_WINNER_FEE_SHARE = 50_000; // 5%
    uint24 constant DEFAULT_POOL_SWAP_FEE = 50_000; // 5%
    bytes constant ZERO_BYTES = bytes("");

    ArbiterAmAmmAnyERC20Hook arbiterHook;

    address user1 = address(0x1111111111111111111111111111111111111111);
    address user2 = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        (currency0, currency1) = deployContractsWithTokens();
        MockERC20(Currency.unwrap(currency0)).mint(
            address(this),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).mint(
            address(this),
            type(uint256).max
        );

        MockERC20 rentToken = new MockERC20("TEST", "TEST", 18);
        rentToken.mint(address(this), 2 ** 255);
        rentCurrency = Currency.wrap(address(rentToken));

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        arbiterHook = new ArbiterAmAmmAnyERC20Hook(
            ICLPoolManager(address(poolManager)),
            ICLPositionManager(address(positionManager)),
            Currency.unwrap(rentCurrency),
            address(this)
        );

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(arbiterHook),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(
                uint256(arbiterHook.getHooksRegistrationBitmap())
            ).setTickSpacing(60)
        });
        poolId = key.toId();

        poolManager.initialize(key, Constants.SQRT_RATIO_1_1);
        poolManager = poolManager;
    }

    function resetCurrentBlock() public {
        CURRENT_BLOCK_NUMBER = STARTING_BLOCK;
        vm.roll(CURRENT_BLOCK_NUMBER);
    }

    function moveBlockBy(uint256 interval) public {
        CURRENT_BLOCK_NUMBER += interval;
        vm.roll(CURRENT_BLOCK_NUMBER);
    }

    function test_ArbiterAmAmmAnyERC20Hook_RewardsPerLiquidityIsZeroAfterInitialize()
        public
        view
    {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 rewardsPerLiquidityInsideX128 = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should be zero after initialize"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_IncreasesWhenInRange() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(
            key,
            10 ether,
            10 ether,
            tickLower,
            tickUpper,
            address(this)
        );
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            1 ether
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            amountIn
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_DoesNotIncreaseWhenOutsideRange()
        public
    {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(
            key,
            10 ether,
            10 ether,
            tickLower,
            tickUpper,
            address(this)
        );
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            1 ether
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128Before = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(tick, 5, "Tick should be 5");
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, int24 tick2, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick2, 5, "Tick should be greater than 5");

        uint256 rewardsPerLiquidityInsideX128After = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128Before,
            rewardsPerLiquidityInsideX128After,
            "Rewards per liquidity inside should not have increased - going right"
        );
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, int24 tick3, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick3, tick2, "Tick should be greater than previous tick");

        uint256 rewardsPerLiquidityInsideX128After2 = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128After,
            rewardsPerLiquidityInsideX128After2,
            "Rewards per liquidity inside should not have increased - going right 2"
        );

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, int24 tick4, , ) = poolManager.getSlot0(key.toId());

        assertLt(
            tick4,
            tick3,
            "Tick should be lesser than previous tick (going left this time)"
        );

        assertGt(tick4, tick, "Tick should be greater than initial tick");

        uint256 rewardsPerLiquidityInsideX128After3 = arbiterHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128After2,
            rewardsPerLiquidityInsideX128After3,
            "Rewards per liquidity inside should not have increased - going left but still outside"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_RewardsCumulativeIsZeroAfterInitialize()
        public
        view
    {
        uint256 rewardsPerLiquidityCumulativeX128 = arbiterHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertEq(
            rewardsPerLiquidityCumulativeX128,
            0,
            "Rewards per liquidity cumulative should be zero after initialize"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_RewardsCumulativeGrowsAfterDonate()
        public
    {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        uint256 rewardsPerLiquidityCumulativeX128Before = arbiterHook
            .getRewardsPerLiquidityCumulativeX128(key);

        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            1 ether
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After = arbiterHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After,
            rewardsPerLiquidityCumulativeX128Before,
            "Rewards per liquidity cumulative should have increased after donate"
        );

        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            1 ether
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After2 = arbiterHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After2,
            rewardsPerLiquidityCumulativeX128After,
            "Rewards per liquidity cumulative should have increased after donate 2"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_TwoPositionsInRange() public {
        currency0.transfer(user1, 1);
        currency1.transfer(user1, 1);
        currency0.transfer(user2, 1);
        currency1.transfer(user2, 1);

        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId1 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user1);
        vm.startPrank(user1);
        positionManager.subscribe(tokenId1, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId2 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user2);
        vm.startPrank(user2);
        positionManager.subscribe(tokenId2, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            1 ether
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        vm.startPrank(user1);
        positionManager.unsubscribe(tokenId1);
        vm.stopPrank();

        vm.startPrank(user2);
        positionManager.unsubscribe(tokenId2);
        vm.stopPrank();

        vm.prank(user1);
        uint256 rewards1 = arbiterHook.collectRewards(user1);

        vm.prank(user2);
        uint256 rewards2 = arbiterHook.collectRewards(user2);

        assertEq(
            rewards1,
            rewards2,
            "Rewards accumulated for both positions should be the same"
        );

        assertApproxEqRel(
            rewards1,
            0.5 ether,
            1e17,
            "Rewards should be split equally between the two positions"
        );
        assertApproxEqRel(
            rewards2,
            0.5 ether,
            1e17,
            "Rewards should be split equally between the two positions"
        );
    }

    function test_ArbiterAmAmmAnyERC20Hook_ComplexAuctionScenario() public {
        resetCurrentBlock();
        addLiquidity(key, 10 ether, 10 ether, -60, 60, address(this));
        address user3 = address(0x3333333333333333333333333333333333333333);
        address user4 = address(0x4444444444444444444444444444444444444444);
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId1 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user3);
        vm.startPrank(user3);
        positionManager.subscribe(tokenId1, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId2 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user4);
        vm.startPrank(user4);
        positionManager.subscribe(tokenId2, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        // Set auction fee to 500 (0.05%)
        arbiterHook.setAuctionFee(key, 500);
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(poolId);
        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");

        // Define rents and strategies
        uint24 feeUser1 = 1000; // 0.1%
        uint24 feeUser2 = 2000; // 0.2%
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        // User1 scenario
        uint80 user1RentPerBlock = 10e18;
        uint128 user1TotalRent = user1RentPerBlock *
            DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6;
        uint128 user1Deposit = user1TotalRent + user1AuctionFee;

        uint256 user1BalancePreDeposit = IERC20(Currency.unwrap(rentCurrency))
            .balanceOf(user1);
        transferRentCurrencyToAndDepositAs(user1Deposit, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            user1RentPerBlock,
            rentEndBlock,
            address(strategyUser1)
        );
        vm.stopPrank();

        moveBlockBy(10);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            amountIn
        );
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            amountIn
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint128 remainingRentAfterSwapUser1 = arbiterHook
            .poolSlot1(poolId)
            .remainingRent();
        assertEq(
            remainingRentAfterSwapUser1,
            user1TotalRent - 10 * user1RentPerBlock,
            "Remaining rent should be reduced by 10 blocks of rent"
        );

        uint256 feeAmountUser1 = (amountIn * feeUser1) / 1e6;
        uint256 expectedFeeAmountUser1 = (feeAmountUser1 *
            DEFAULT_WINNER_FEE_SHARE) / 1e6;
        uint256 strategyUser1Balance = vault.balanceOf(
            address(strategyUser1),
            key.currency0
        );
        assertEq(
            strategyUser1Balance,
            expectedFeeAmountUser1,
            "Strategy user1 did not receive correct fees after first swap"
        );

        uint80 user2RentPerBlock = 20e18;
        uint128 user2TotalRent = user2RentPerBlock *
            DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6;
        uint128 user2Deposit = user2TotalRent + user2AuctionFee;

        uint32 rentEndBlock2 = uint32(
            STARTING_BLOCK + 10 + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferRentCurrencyToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            user2RentPerBlock,
            rentEndBlock2,
            address(strategyUser2)
        );
        vm.stopPrank();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user2, "User2 should be the new winner");

        (
            uint128 initialRemainingRent,
            uint128 feeLocked,
            uint128 collectedFee
        ) = arbiterHook.auctionFees(poolId);
        assertEq(
            feeLocked,
            user2AuctionFee,
            "Auction fee should be locked for user2"
        );
        assertEq(
            initialRemainingRent,
            user2TotalRent,
            "Initial remaining rent should be equal to user2's total rent"
        );

        uint128 feeRefund = uint128(
            (uint256(user1AuctionFee) * remainingRentAfterSwapUser1) /
                user1TotalRent
        );
        assertEq(
            collectedFee,
            user1AuctionFee - feeRefund,
            "Collected fee should equal user1's auction fee minus the refunded portion"
        );

        moveBlockBy(10);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            amountIn
        );
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            amountIn
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 *
            DEFAULT_WINNER_FEE_SHARE) / 1e6;
        uint256 strategyUser2Balance = vault.balanceOf(
            address(strategyUser2),
            key.currency0
        );
        assertEq(
            strategyUser2Balance,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive correct fees after second swap"
        );

        uint256 user1FinalDeposit = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1FinalDeposit);
        vm.stopPrank();

        uint256 user1FinalDepositAfter = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            user1FinalDepositAfter,
            0,
            "User1 should be able to withdraw the entire refunded deposit"
        );

        uint256 user1BalancePostWithdraw = IERC20(Currency.unwrap(rentCurrency))
            .balanceOf(user1);
        assertTrue(
            user1BalancePostWithdraw >= user1BalancePreDeposit,
            "User1 should end up with at least their initial balance after refunds"
        );

        vm.startPrank(user3);
        positionManager.unsubscribe(tokenId1);
        vm.stopPrank();

        vm.startPrank(user4);
        positionManager.unsubscribe(tokenId2);
        vm.stopPrank();

        // check user3 and user4 rewards
        vm.prank(user3);
        uint256 rewards3 = arbiterHook.collectRewards(user3);

        vm.prank(user4);
        uint256 rewards4 = arbiterHook.collectRewards(user4);

        uint256 expectedRewardsPerLP = ((user1RentPerBlock * 10) +
            (user2RentPerBlock * 10)) / 2;

        assertApproxEqRel(
            rewards3,
            expectedRewardsPerLP,
            1e17,
            "Rewards should be equal to expected rewards"
        );
        assertApproxEqRel(
            rewards4,
            expectedRewardsPerLP,
            1e17,
            "Rewards should be equal to expected rewards"
        );

        uint256 user3Balance = vault.balanceOf(user3, rentCurrency);
        uint256 user4Balance = vault.balanceOf(user4, rentCurrency);

        assertEq(
            rewards3,
            user3Balance,
            "Rewards should be equal to user3 balance"
        );
        assertEq(
            rewards4,
            user4Balance,
            "Rewards should be equal to user4 balance"
        );
    }

    function transferRentCurrencyToAndDepositAs(
        uint256 amount,
        address user
    ) public {
        IERC20(Currency.unwrap(rentCurrency)).transfer(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(rentCurrency)).approve(
            address(arbiterHook),
            amount
        );
        arbiterHook.deposit(Currency.unwrap(rentCurrency), amount);
        vm.stopPrank();
    }
}
