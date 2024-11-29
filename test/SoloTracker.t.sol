// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import {Test} from "forge-std/Test.sol";

// import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
// import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
// import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
// import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
// import {Vault} from "pancake-v4-core/src/Vault.sol";
// import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
// import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
// import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
// import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
// import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {MockCLSwapRouter} from "./pool-cl/helpers/MockCLSwapRouter.sol";
// import {MockCLPositionManager} from "./pool-cl/helpers/MockCLPositionManager.sol";
// import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
// import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
// import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
// import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
// import {ICLPositionDescriptor} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
// import {CLPositionDescriptorOffChain} from "pancake-v4-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
// import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
// import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
// import {CLTestUtils} from "./pool-cl/utils/CLTestUtils.sol";
// import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
// import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {SoloTracker} from "../src/SoloTracker.sol";
// import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
// import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
// import "forge-std/console.sol";

// contract SoloTrackerHookTest is Test, CLTestUtils {
//     using LPFeeLibrary for uint24;
//     using PoolIdLibrary for PoolKey;
//     using CLPoolParametersHelper for bytes32;
//     using CurrencyLibrary for Currency;

//     uint24 constant DEFAULT_SWAP_FEE = 300;
//     uint24 constant DEFAULT_WINNER_FEE_SHARE = 50000;
//     uint24 constant MAX_FEE = 10000;
//     bytes constant ZERO_BYTES = bytes("");

//     MockCLSwapRouter swapRouter;

//     SoloTracker soloTrackerHook;

//     MockERC20 weth;
//     Currency currency0;
//     Currency currency1;
//     PoolKey key;
//     PoolId id;

//     address user1 = address(0x1111111111111111111111111111111111111111);
//     address user2 = address(0x2222222222222222222222222222222222222222);

//     function setUp() public {
//         (currency0, currency1) = deployContractsWithTokens();

//         // Deploy the solo tracker hook with required parameters
//         soloTrackerHook = new SoloTracker(
//             ICLPoolManager(address(poolManager)),
//             ICLPositionManager(address(positionManager))
//         );

//         key = PoolKey({
//             currency0: currency0,
//             currency1: currency1,
//             hooks: IHooks(soloTrackerHook),
//             poolManager: IPoolManager(address(poolManager)),
//             fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
//             parameters: bytes32(
//                 uint256(soloTrackerHook.getHooksRegistrationBitmap())
//             ).setTickSpacing(60)
//         });
//         id = key.toId();

//         // Initialize the pool with a price of 1:1
//         poolManager.initialize(key, Constants.SQRT_RATIO_1_1);

//         MockERC20(Currency.unwrap(currency0)).mint(
//             address(this),
//             type(uint256).max
//         );
//         MockERC20(Currency.unwrap(currency1)).mint(
//             address(this),
//             type(uint256).max
//         );

//         console.log("currency0: ", address(Currency.unwrap(currency0)));
//         console.log("currency1: ", address(Currency.unwrap(currency1)));
//         console.log("user1", user1);
//         // console.log("user2", user2);
//         console.log("this", address(this));
//         console.log("vault", address(vault));
//         console.log("universalRouter", address(universalRouter));
//         console.log("soloTrackerHook", address(soloTrackerHook));
//     }

//     function moveBlockBy(uint256 interval) public {
//         vm.roll(block.number + interval);
//     }

//     // it('is zero immediately after initialize', async () => {
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(0)
//     //     expect(tickCumulativeInside).to.eq(0)
//     //     expect(secondsInside).to.eq(0)
//     // })
//     // it('increases by expected amount when time elapses in the range', async () => {
//     //     await pool.advanceTime(5)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(5).shl(128).div(10))
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(0)
//     //     expect(secondsInside).to.eq(5)
//     // })
//     // it('does not account for time increase above range', async () => {
//     //     await pool.advanceTime(5)
//     //     await swapToHigherPrice(encodePriceSqrt(2, 1), wallet.address)
//     //     await pool.advanceTime(7)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(5).shl(128).div(10))
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(0)
//     //     expect(secondsInside).to.eq(5)
//     // })
//     // it('does not account for time increase below range', async () => {
//     //     await pool.advanceTime(5)
//     //     await swapToLowerPrice(encodePriceSqrt(1, 2), wallet.address)
//     //     await pool.advanceTime(7)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(5).shl(128).div(10))
//     //     // tick is 0 for 5 seconds, then not in range
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(0)
//     //     expect(secondsInside).to.eq(5)
//     // })
//     // it('time increase below range is not counted', async () => {
//     //     await swapToLowerPrice(encodePriceSqrt(1, 2), wallet.address)
//     //     await pool.advanceTime(5)
//     //     await swapToHigherPrice(encodePriceSqrt(1, 1), wallet.address)
//     //     await pool.advanceTime(7)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(7).shl(128).div(10))
//     //     // tick is not in range then tick is 0 for 7 seconds
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(0)
//     //     expect(secondsInside).to.eq(7)
//     // })
//     // it('time increase above range is not counted', async () => {
//     //     await swapToHigherPrice(encodePriceSqrt(2, 1), wallet.address)
//     //     await pool.advanceTime(5)
//     //     await swapToLowerPrice(encodePriceSqrt(1, 1), wallet.address)
//     //     await pool.advanceTime(7)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(7).shl(128).div(10))
//     //     expect((await pool.slot0()).tick).to.eq(-1) // justify the -7 tick cumulative inside value
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(-7)
//     //     expect(secondsInside).to.eq(7)
//     // })
//     // it('positions minted after time spent', async () => {
//     //     await pool.advanceTime(5)
//     //     await mint(wallet.address, tickUpper, getMaxTick(tickSpacing), 15)
//     //     await swapToHigherPrice(encodePriceSqrt(2, 1), wallet.address)
//     //     await pool.advanceTime(8)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickUpper, getMaxTick(tickSpacing))
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(8).shl(128).div(15))
//     //     // the tick of 2/1 is 6931
//     //     // 8 seconds * 6931 = 55448
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(55448)
//     //     expect(secondsInside).to.eq(8)
//     // })
//     // it('overlapping liquidity is aggregated', async () => {
//     //     await mint(wallet.address, tickLower, getMaxTick(tickSpacing), 15)
//     //     await pool.advanceTime(5)
//     //     await swapToHigherPrice(encodePriceSqrt(2, 1), wallet.address)
//     //     await pool.advanceTime(8)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(tickLower, tickUpper)
//     //     expect(secondsPerLiquidityInsideX128).to.eq(BigNumber.from(5).shl(128).div(25))
//     //     expect(tickCumulativeInside, 'tickCumulativeInside').to.eq(0)
//     //     expect(secondsInside).to.eq(5)
//     // })
//     // it('relative behavior of snapshots', async () => {
//     //     await pool.advanceTime(5)
//     //     await mint(wallet.address, getMinTick(tickSpacing), tickLower, 15)
//     //     const {
//     //     secondsPerLiquidityInsideX128: secondsPerLiquidityInsideX128Start,
//     //     tickCumulativeInside: tickCumulativeInsideStart,
//     //     secondsInside: secondsInsideStart,
//     //     } = await pool.snapshotCumulativesInside(getMinTick(tickSpacing), tickLower)
//     //     await pool.advanceTime(8)
//     //     // 13 seconds in starting range, then 3 seconds in newly minted range
//     //     await swapToLowerPrice(encodePriceSqrt(1, 2), wallet.address)
//     //     await pool.advanceTime(3)
//     //     const { secondsPerLiquidityInsideX128, tickCumulativeInside, secondsInside } =
//     //     await pool.snapshotCumulativesInside(getMinTick(tickSpacing), tickLower)
//     //     const expectedDiffSecondsPerLiquidity = BigNumber.from(3).shl(128).div(15)
//     //     expect(secondsPerLiquidityInsideX128.sub(secondsPerLiquidityInsideX128Start)).to.eq(
//     //     expectedDiffSecondsPerLiquidity
//     //     )
//     //     expect(secondsPerLiquidityInsideX128).to.not.eq(expectedDiffSecondsPerLiquidity)
//     //     // the tick is the one corresponding to the price of 1/2, or log base 1.0001 of 0.5
//     //     // this is -6932, and 3 seconds have passed, so the cumulative computed from the diff equals 6932 * 3
//     //     expect(tickCumulativeInside.sub(tickCumulativeInsideStart), 'tickCumulativeInside').to.eq(-20796)
//     //     expect(secondsInside - secondsInsideStart).to.eq(3)
//     //     expect(secondsInside).to.not.eq(3)
//     // })
//     function test_SecondsPerLiquidityIsZeroAfterInitialize() public {
//         int24 tickLower = -60;
//         int24 tickUpper = 60;

//         uint256 secondsPerLiquidityInsideX128 = soloTrackerHook
//             .getSecondsPerLiquidityInsideX128(key, tickLower, tickUpper);

//         assertEq(
//             secondsPerLiquidityInsideX128,
//             0,
//             "Seconds per liquidity inside should be zero after initialize"
//         );
//     }

//     function test_IncreasesByExpectedAmountWhenTimeElapsesInRange() public {
//         int24 tickLower = -60;
//         int24 tickUpper = 60;

//         uint256 tokenId = positionManager.nextTokenId();
//         addLiquidity(key, 10 ether, 10 ether, -6000, 6000, address(this));

//         positionManager.subscribe(
//             tokenId,
//             address(soloTrackerHook),
//             ZERO_BYTES
//         );

//         vm.warp(block.timestamp + 5);

//         IERC20(Currency.unwrap(currency0)).approve(
//             address(swapRouter),
//             1 ether
//         );

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: 1 ether,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         uint256 secondsPerLiquidityInsideX128 = soloTrackerHook
//             .getSecondsPerLiquidityInsideX128(key, tickLower, tickUpper);

//         assertGt(
//             secondsPerLiquidityInsideX128,
//             0,
//             "Seconds per liquidity inside should have increased"
//         );
//     }

//     function logSlot0() public {
//         (
//             uint160 sqrtPriceX96,
//             int24 tick,
//             uint24 protocolFee,
//             uint24 lpFee
//         ) = poolManager.getSlot0(key.toId());
//         console.log("sqrtPriceX96: ", sqrtPriceX96);
//         console.log("tick: ", tick);
//         console.log("protocolFee: ", protocolFee);
//         console.log("lpFee: ", lpFee);
//     }

//     // ... similarly rewrite other tests ...
// }
