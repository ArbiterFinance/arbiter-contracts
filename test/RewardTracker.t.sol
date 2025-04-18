// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCLSwapRouter} from "./pool-cl/helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./pool-cl/helpers/MockCLPositionManager.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLTestUtils} from "./pool-cl/utils/CLTestUtils.sol";
import {Constants} from "infinity-core/test/pool-cl/helpers/Constants.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RewardTracker} from "../src/RewardTracker.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolExtension} from "../src/libraries/PoolExtension.sol";
import {PositionExtension} from "../src/libraries/PositionExtension.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "infinity-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {NoOpRewardTracker} from "./contracts/NoOpRewardTracker.sol";

contract RewardTrackerHookTest is Test, CLTestUtils {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    bytes constant ZERO_BYTES = bytes("");

    MockCLSwapRouter swapRouter;

    NoOpRewardTracker trackerHook;

    MockERC20 weth;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;

    address user1 = address(0x1111111111111111111111111111111111111111);
    address user2 = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        _setUp(Constants.SQRT_RATIO_1_1);
    }
    function _setUp(uint160 sqrtPriceX96) public {
        (currency0, currency1) = deployContractsWithTokens();

        // Deploy the solo tracker hook with required parameters
        trackerHook = new NoOpRewardTracker(
            ICLPoolManager(address(poolManager)),
            ICLPositionManager(address(positionManager))
        );

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(trackerHook),
            poolManager: IPoolManager(address(poolManager)),
            fee: 3000,
            parameters: bytes32(
                uint256(trackerHook.getHooksRegistrationBitmap())
            ).setTickSpacing(60)
        });
        poolId = key.toId();

        poolManager.initialize(key, sqrtPriceX96);

        MockERC20(Currency.unwrap(currency0)).mint(
            address(this),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).mint(
            address(this),
            type(uint256).max
        );
    }

    function test_RewardTrackerHookTest_RewardsPerLiquidityIsZeroAfterInitialize()
        public
    {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should be zero after initialize"
        );
    }

    function test_RewardTrackerHookTest_IncreasesWhenInRange() public {
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
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );
    }

    function test_RewardTrackerHookTest_IncreasesWhenInRangeSqrtRatio_1_4_ZeroForOne()
        public
    {
        _setUp(Constants.SQRT_RATIO_1_4);
        int24 tickLower = -16_200;
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
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );

        (, , int24 tickFromRewardTracker) = trackerHook.pools(poolId);
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(
            tick,
            tickFromRewardTracker,
            "Tick from reward tracker should be equal to the pool tick"
        );
    }

    function test_RewardTrackerHookTest_IncreasesWhenInRangeSqrtRatio_1_4_OneForZero()
        public
    {
        _setUp(Constants.SQRT_RATIO_1_4);
        int24 tickLower = -16_200;
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
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );

        (, , int24 tickFromRewardTracker) = trackerHook.pools(poolId);
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(
            tick,
            tickFromRewardTracker,
            "Tick from reward tracker should be equal to the pool tick"
        );
    }

    function test_RewardTrackerHookTest_IncreasesWhenInRangeSqrtRatio_4_1_ZeroForOne()
        public
    {
        _setUp(Constants.SQRT_RATIO_4_1);
        int24 tickLower = -60;
        int24 tickUpper = 16_200;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(
            key,
            10 ether,
            10 ether,
            tickLower,
            tickUpper,
            address(this)
        );
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );

        (, , int24 tickFromRewardTracker) = trackerHook.pools(poolId);
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(
            tick,
            tickFromRewardTracker,
            "Tick from reward tracker should be equal to the pool tick"
        );
    }

    function test_RewardTrackerHookTest_IncreasesWhenInRangeSqrtRatio_4_1_OneForZero()
        public
    {
        _setUp(Constants.SQRT_RATIO_4_1);
        int24 tickLower = -60;
        int24 tickUpper = 16_200;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(
            key,
            10 ether,
            10 ether,
            tickLower,
            tickUpper,
            address(this)
        );
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(
            rewardsPerLiquidityInsideX128,
            0,
            "Rewards per liquidity inside should have increased"
        );

        (, , int24 tickFromRewardTracker) = trackerHook.pools(poolId);
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(
            tick,
            tickFromRewardTracker,
            "Tick from reward tracker should be equal to the pool tick"
        );
    }

    function test_RewardTrackerHookTest_DoesNotIncreaseWhenOutsideRange()
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
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 rewardsPerLiquidityInsideX128Before = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        (, , int24 tickFromRewardTracker) = trackerHook.pools(poolId);
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(tick, 5, "Tick should be 5");
        assertEq(
            tickFromRewardTracker,
            tick,
            "Tick from reward tracker should be equal to the pool tick"
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, , int24 tickFromRewardTracker2) = trackerHook.pools(poolId);
        (, int24 tick2, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick2, 5, "Tick should be greater than 5");
        assertEq(
            tickFromRewardTracker2,
            tick2,
            "Tick from reward tracker should be equal to the pool tick 2"
        );

        uint256 rewardsPerLiquidityInsideX128After = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128Before,
            rewardsPerLiquidityInsideX128After,
            "Rewards per liquidity inside should not have increased - going right"
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, , int24 tickFromRewardTracker3) = trackerHook.pools(poolId);
        (, int24 tick3, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick3, tick2, "Tick should be greater than previous tick");
        assertEq(
            tickFromRewardTracker3,
            tick3,
            "Tick from reward tracker should be equal to the pool tick 3"
        );

        uint256 rewardsPerLiquidityInsideX128After2 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128After,
            rewardsPerLiquidityInsideX128After2,
            "Rewards per liquidity inside should not have increased - going right 2"
        );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (, , int24 tickFromRewardTracker4) = trackerHook.pools(poolId);
        (, int24 tick4, , ) = poolManager.getSlot0(key.toId());

        assertLt(
            tick4,
            tick3,
            "Tick should be lesser than previous tick (going left this time)"
        );
        assertEq(
            tickFromRewardTracker4,
            tick4,
            "Tick from reward tracker should be equal to the pool tick 4"
        );

        assertGt(tick4, tick, "Tick should be greater than initial tick");

        uint256 rewardsPerLiquidityInsideX128After3 = trackerHook
            .getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(
            rewardsPerLiquidityInsideX128After2,
            rewardsPerLiquidityInsideX128After3,
            "Rewards per liquidity inside should not have increased - going left but still outside"
        );
    }

    function test_RewardTrackerHookTest_RewardsCumulativeIsZeroAfterInitialize()
        public
    {
        uint256 rewardsPerLiquidityCumulativeX128 = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertEq(
            rewardsPerLiquidityCumulativeX128,
            0,
            "Rewards per liquidity cumulative should be zero after initialize"
        );
    }

    function test_RewardTrackerHookTest_RewardsCumulativeGrowsAfterDonate()
        public
    {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        uint256 rewardsPerLiquidityCumulativeX128Before = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        trackerHook.donateRewards(poolId, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After,
            rewardsPerLiquidityCumulativeX128Before,
            "Rewards per liquidity cumulative should have increased after donate"
        );

        trackerHook.donateRewards(poolId, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After2 = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After2,
            rewardsPerLiquidityCumulativeX128After,
            "Rewards per liquidity cumulative should have increased after donate 2"
        );
    }

    function test_RewardTrackerHookTest_AccrueRewards() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        trackerHook.accrueRewards(tokenId);

        uint256 rewards = trackerHook.accruedRewards(address(this));

        assertGt(
            rewards,
            0,
            "Rewards should have been accumulated for the position"
        );
    }

    function test_RewardTrackerHookTest_CollectRewards() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(trackerHook), ZERO_BYTES);

        trackerHook.donateRewards(poolId, 1 ether);

        trackerHook.accrueRewards(tokenId);

        uint256 rewards = trackerHook.accruedRewards(address(this));

        assertGt(
            rewards,
            0,
            "Rewards should have been accumulated for the position"
        );

        trackerHook.collectRewards(address(this));

        uint256 rewardsPerLiquidityCumulativeX128Before = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        uint256 rewardsAfter = trackerHook.accruedRewards(address(this));

        assertEq(
            rewardsAfter,
            0,
            "Accrued rewards should be reset after collecting rewards"
        );

        //cumulative rewards should not be reset
        uint256 rewardsPerLiquidityCumulativeX128After = trackerHook
            .getRewardsPerLiquidityCumulativeX128(key);

        assertEq(
            rewardsPerLiquidityCumulativeX128Before,
            rewardsPerLiquidityCumulativeX128After,
            "Rewards per liquidity cumulative should not be reset after collecting rewards"
        );

        // add more rewards, accrue and collect again

        trackerHook.donateRewards(poolId, 1 ether);

        trackerHook.accrueRewards(tokenId);

        uint256 rewards2 = trackerHook.accruedRewards(address(this));

        assertEq(
            rewards,
            rewards2,
            "Rewards accumulated for the position should be the same"
        );
    }

    // two positions by user1 and user 2, both in range, same liquidity

    function test_RewardTrackerHookTest_TwoPositionsInRange() public {
        currency0.transfer(user1, 1);
        currency1.transfer(user1, 1);
        currency0.transfer(user2, 1);
        currency1.transfer(user2, 1);
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId1 = positionManager.nextTokenId();

        addLiquidity(key, 1, 1, tickLower, tickUpper, user1);
        vm.startPrank(user1);
        positionManager.subscribe(tokenId1, address(trackerHook), ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId2 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user2);
        vm.startPrank(user2);
        positionManager.subscribe(tokenId2, address(trackerHook), ZERO_BYTES);
        vm.stopPrank();

        trackerHook.donateRewards(poolId, 1 ether);

        trackerHook.accrueRewards(tokenId1);
        trackerHook.accrueRewards(tokenId2);

        uint256 rewards1 = trackerHook.accruedRewards(user1);
        uint256 rewards2 = trackerHook.accruedRewards(user2);

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
}
