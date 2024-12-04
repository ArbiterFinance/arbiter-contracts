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
// import {IArbiterFeeProvider} from "../src/interfaces/IArbiterFeeProvider.sol";
// import {IArbiterAmAmmHarbergerLease} from "../src/interfaces/IArbiterAmAmmHarbergerLease.sol";
// import {ArbiterAmAmmSimpleHook, DEFAULT_WINNER_FEE_SHARE, DEFAULT_MAX_POOL_SWAP_FEE, DEFAULT_MINIMUM_RENT_BLOCKS, DEFAULT_OVERBID_FACTOR, DEFAULT_TRANSITION_BLOCKS} from "../src/ArbiterAmAmmSimpleHook.sol";
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

// import {AuctionSlot0, AuctionSlot0Library} from "../src/types/AuctionSlot0.sol";
// import {AuctionSlot1, AuctionSlot1Library} from "../src/types/AuctionSlot1.sol";

// import "forge-std/console.sol";

// contract MockStrategy is IArbiterFeeProvider {
//     uint24 public fee;

//     constructor(uint24 _fee) {
//         fee = _fee;
//     }

//     function getSwapFee(
//         address,
//         PoolKey calldata,
//         ICLPoolManager.SwapParams calldata,
//         bytes calldata
//     ) external view returns (uint24) {
//         return fee;
//     }

//     function setFee(uint24 _fee) external {
//         fee = _fee;
//     }
// }

// contract ArbiterAmAmmSimpleHookTest is Test, CLTestUtils {
//     using LPFeeLibrary for uint24;
//     using PoolIdLibrary for PoolKey;
//     using CLPoolParametersHelper for bytes32;
//     using CurrencyLibrary for Currency;
//     using AuctionSlot0Library for AuctionSlot0;
//     using AuctionSlot1Library for AuctionSlot1;

//     uint24 constant DEFAULT_SWAP_FEE = 300;
//     bytes constant ZERO_BYTES = bytes("");
//     uint256 constant STARTING_BLOCK = 10000000;

//     MockCLSwapRouter swapRouter;

//     ArbiterAmAmmSimpleHook arbiterHook;

//     MockERC20 weth;
//     Currency currency0;
//     Currency currency1;
//     PoolKey key;
//     PoolId id;

//     address user1 = address(0x1111111111111111111111111111111111111111);
//     address user2 = address(0x2222222222222222222222222222222222222222);

//     function setUp() public {
//         moveBlockBy(STARTING_BLOCK - block.number);
//         (currency0, currency1) = deployContractsWithTokens();

//         // Deploy the arbiter hook with required parameters
//         arbiterHook = new ArbiterAmAmmSimpleHook(
//             ICLPoolManager(address(poolManager)),
//             true, // RENT_IN_TOKEN_ZERO
//             address(this),
//             DEFAULT_TRANSITION_BLOCKS,
//             DEFAULT_MINIMUM_RENT_BLOCKS,
//             DEFAULT_OVERBID_FACTOR
//         );

//         key = PoolKey({
//             currency0: currency0,
//             currency1: currency1,
//             hooks: IHooks(arbiterHook),
//             poolManager: IPoolManager(address(poolManager)),
//             fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
//             parameters: bytes32(
//                 uint256(arbiterHook.getHooksRegistrationBitmap())
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
//         // Add liquidity
//         addLiquidity(key, 10 ether, 10 ether, -60, 60, address(this));

//         console.log("currency0: ", address(Currency.unwrap(currency0)));
//         console.log("currency1: ", address(Currency.unwrap(currency1)));
//         console.log("user1", user1);
//         // console.log("user2", user2);
//         console.log("this", address(this));
//         console.log("vault", address(vault));
//         console.log("universalRouter", address(universalRouter));
//         console.log("arbiterHook", address(arbiterHook));
//     }

//     function transferToUser1AndDepositAs(uint256 amount) public {
//         currency0.transfer(user1, amount);
//         vm.startPrank(user1);
//         IERC20(Currency.unwrap(currency0)).approve(
//             address(arbiterHook),
//             amount
//         );
//         arbiterHook.deposit(Currency.unwrap(currency0), amount);
//         vm.stopPrank();
//     }

//     function moveBlockBy(uint256 interval) public {
//         vm.roll(block.number + interval);
//     }

//     function testBiddingAndRentPayment() public {
//         transferToUser1AndDepositAs(10_000e18);
//         //offset blocks
//         moveBlockBy(100);

//         // User1 overbids
//         vm.prank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0) // strategy (none)
//         );
//         AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
//         uint128 startingRent = slot1.remainingRent();

//         address winner = arbiterHook.winner(key);
//         assertEq(winner, user1, "Winner should be user1 after overbidding");

//         moveBlockBy(5);
//         addLiquidity(key, 1, 1, -60, 60, address(this));

//         slot1 = arbiterHook.poolSlot1(id);
//         uint128 remainingRent = slot1.remainingRent();
//         assertEq(
//             startingRent - remainingRent,
//             5 * 10e18,
//             "Remaining rent should be less than initial deposit"
//         );

//         // add liquidity
//         addLiquidity(key, 1, 1, -60, 60, address(this));

//         // TODO: test rent payment
//     }

//     function testStrategyContractSetsFee() public {
//         // Deploy a mock strategy that sets swap fee to DEFAULT_MAX_POOL_SWAP_FEE
//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);

//         // User1 deposits and overbids with the strategy
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);

//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         uint256 prevBalance0 = key.currency0.balanceOf(address(this));
//         uint256 prevBalance1 = key.currency1.balanceOf(address(this));

//         uint128 amountIn = 1e18;
//         moveBlockBy(1);

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         uint256 postBalance0 = key.currency0.balanceOf(address(this));
//         uint256 postBalance1 = key.currency1.balanceOf(address(this));

//         uint256 feeAmount = (amountIn * DEFAULT_MAX_POOL_SWAP_FEE) / 1e6;
//         uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
//             127;

//         assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

//         assertEq(
//             poolManager.protocolFeesAccrued(key.currency0),
//             0,
//             "Protocol fees accrued in currency0 should be zero"
//         );
//         assertEq(
//             poolManager.protocolFeesAccrued(key.currency0),
//             0,
//             "Protocol fees accrued in currency0 should be zero"
//         );

//         uint256 strategyBalance = vault.balanceOf(
//             address(strategy),
//             key.currency1
//         );
//         assertEq(
//             strategyBalance,
//             expectedFeeAmount,
//             "Strategy balance does not match expected fee amount"
//         );
//     }

//     function testStrategyFeeCappedAtMaxFee() public {
//         // Deploy a mock strategy that sets swap fee to a value greater than DEFAULT_MAX_POOL_SWAP_FEE
//         uint24 strategyFee = DEFAULT_MAX_POOL_SWAP_FEE + 1000; // Fee greater than DEFAULT_MAX_POOL_SWAP_FEE
//         MockStrategy strategy = new MockStrategy(strategyFee);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         moveBlockBy(1);
//         vm.stopPrank();

//         // Record initial balances
//         uint256 prevBalance0 = key.currency0.balanceOf(address(this));
//         uint256 prevBalance1 = key.currency1.balanceOf(address(this));

//         // Perform a swap
//         uint128 amountIn = 1e18;
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         // Record final balances
//         uint256 postBalance0 = key.currency0.balanceOf(address(this));
//         uint256 postBalance1 = key.currency1.balanceOf(address(this));

//         uint256 feeAmount = (amountIn * DEFAULT_MAX_POOL_SWAP_FEE) / 1e6;
//         uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
//             127;

//         assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

//         uint256 strategyBalance = vault.balanceOf(
//             address(strategy),
//             key.currency1
//         );
//         assertEq(
//             strategyBalance,
//             expectedFeeAmount,
//             "Strategy balance should match expected fee amount"
//         );
//     }

//     function testDepositAndWithdraw() public {
//         // User1 deposits currency0

//         transferToUser1AndDepositAs(100e18);

//         uint256 depositBalance = arbiterHook.depositOf(
//             Currency.unwrap(currency0),
//             user1
//         );
//         assertEq(
//             depositBalance,
//             100e18,
//             "Deposit amount does not match expected value"
//         );

//         // User1 withdraws half
//         vm.startPrank(user1);
//         arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);

//         depositBalance = arbiterHook.depositOf(
//             Currency.unwrap(currency0),
//             user1
//         );
//         assertEq(
//             depositBalance,
//             50e18,
//             "Deposit balance should be 50e18 after withdrawing half"
//         );

//         // withdraws the rest
//         arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);
//         depositBalance = arbiterHook.depositOf(
//             Currency.unwrap(currency0),
//             user1
//         );
//         assertEq(
//             depositBalance,
//             0,
//             "Deposit balance should be zero after withdrawing all"
//         );

//         vm.stopPrank();
//     }

//     function testChangeStrategy() public {
//         // User1 overbids and becomes the winner
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0)
//         );
//         vm.stopPrank();

//         // User1 changes strategy
//         MockStrategy newStrategy = new MockStrategy(5000);
//         vm.prank(user1);
//         arbiterHook.changeStrategy(key, address(newStrategy));

//         address currentStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             currentStrategy,
//             address(newStrategy),
//             "Active strategy should be updated to new strategy"
//         );
//     }

//     function testRevertIfNotDynamicFee() public {
//         PoolKey memory nonDynamicKey = PoolKey({
//             currency0: currency0,
//             currency1: currency1,
//             hooks: arbiterHook,
//             poolManager: poolManager,
//             fee: DEFAULT_SWAP_FEE,
//             parameters: bytes32(
//                 uint256(arbiterHook.getHooksRegistrationBitmap())
//             ).setTickSpacing(60)
//         });

//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 Hooks.Wrap__FailedHookCall.selector,
//                 address(arbiterHook),
//                 abi.encodeWithSelector(
//                     IArbiterAmAmmHarbergerLease.NotDynamicFee.selector
//                 )
//             )
//         );
//         poolManager.initialize(nonDynamicKey, Constants.SQRT_RATIO_1_1);
//     }

//     function testRentTooLow() public {
//         // User1 deposits currency0
//         transferToUser1AndDepositAs(10_000e18);

//         vm.prank(user1);
//         arbiterHook.overbid(
//             key,
//             1e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0)
//         );
//         vm.expectRevert(IArbiterAmAmmHarbergerLease.RentTooLow.selector);
//         arbiterHook.overbid(
//             key,
//             1e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0)
//         );
//     }

//     function testNotWinnerCannotChangeStrategy() public {
//         // User1 overbids and becomes the winner
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0)
//         );
//         vm.stopPrank();

//         // User2 tries to change strategy
//         vm.prank(user2);
//         vm.expectRevert(IArbiterAmAmmHarbergerLease.CallerNotWinner.selector);
//         arbiterHook.changeStrategy(key, address(0));
//     }

//     function testDefaultFeeWhenNoOneHasWon() public {
//         // Ensure there is no winner and no strategy set
//         address currentWinner = arbiterHook.winner(key);
//         address currentStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             currentWinner,
//             address(0),
//             "Initial winner should be address(0)"
//         );
//         assertEq(
//             currentStrategy,
//             address(0),
//             "Initial strategy should be address(0)"
//         );

//         uint128 amountIn = 1e18;
//         currency0.transfer(user1, 1000e18);

//         // Record initial balances
//         uint256 prevBalance0 = key.currency0.balanceOf(address(user1));
//         uint256 prevBalance1 = key.currency1.balanceOf(address(user1));

//         assertEq(prevBalance0, 1000e18, "Initial balance0 mismatch");
//         assertEq(prevBalance1, 0, "Initial balance1 mismatch");

//         // Perform a swap
//         permit2Approve(user1, currency0, address(universalRouter));
//         vm.startPrank(user1);
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );
//         vm.stopPrank();

//         // Record final balances
//         uint256 postBalance0 = key.currency0.balanceOf(address(user1));
//         uint256 postBalance1 = key.currency1.balanceOf(address(user1));

//         // Calculate the expected fee using DEFAULT_SWAP_FEE
//         uint256 feeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;
//         uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
//             127;

//         assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

//         uint256 strategyBalance = vault.balanceOf(
//             address(currentStrategy),
//             key.currency1
//         );
//         assertEq(
//             strategyBalance,
//             0,
//             "Strategy balance should be zero when no one has won"
//         );
//     }

//     function testDefaultFeeAfterAuctionWinExpired() public {
//         // Deploy a mock strategy that sets swap fee to DEFAULT_MAX_POOL_SWAP_FEE
//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);

//         // User1 deposits and overbids with the strategy
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);

//         // Set rent to expire in 300 blocks
//         uint32 rentEndBlock = uint32(
//             block.number + DEFAULT_MINIMUM_RENT_BLOCKS
//         );
//         console.log("rentEndBlock: ", rentEndBlock);
//         console.log("current block: ", block.number);
//         arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategy));
//         vm.stopPrank();
//         moveBlockBy(1);

//         uint128 amountIn = 1e18;
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );
//         moveBlockBy(DEFAULT_MINIMUM_RENT_BLOCKS - 1);

//         uint32 currentBlock = uint32(block.number);
//         AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
//         uint64 rentEndBlockFromContract = slot1.rentEndBlock();
//         assertEq(
//             currentBlock,
//             rentEndBlockFromContract,
//             "currentBlock vs rent end block mismatch"
//         );

//         moveBlockBy(1);

//         // Record initial balances
//         uint256 prevBalance0 = key.currency0.balanceOf(address(this));
//         uint256 prevBalance1 = key.currency1.balanceOf(address(this));

//         // Perform a swap
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         uint256 strategyBalance = vault.balanceOf(
//             address(strategy),
//             key.currency1
//         );

//         assertGt(
//             strategyBalance,
//             0,
//             "Strategy balance should be greater than zero after rent expiry"
//         );

//         moveBlockBy(1);

//         //trigger _payRent
//         console.log("triggering _payRent");
//         addLiquidity(key, 1, 1, -60, 60, address(this));

//         address currentWinner = arbiterHook.winner(key);
//         assertEq(
//             currentWinner,
//             address(0),
//             "Winner should be reset to address(0) after rent expiry"
//         );

//         // Record final balances
//         uint256 postBalance0 = key.currency0.balanceOf(address(this));
//         uint256 postBalance1 = key.currency1.balanceOf(address(this));

//         uint256 feeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;
//         uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
//             127;

//         console.log("prevBalance0: ", prevBalance0);
//         console.log("postBalance0: ", postBalance0);
//         console.log("amountIn: ", amountIn);
//         console.log("expectedFeeAmount: ", expectedFeeAmount);

//         assertApproxEqRel(
//             prevBalance0 - postBalance0,
//             amountIn,
//             1,
//             "Amount in mismatch"
//         );

//         uint256 strategyBalancePostExpiry = vault.balanceOf(
//             address(strategy),
//             key.currency1
//         );
//         assertEq(
//             strategyBalancePostExpiry,
//             strategyBalance,
//             "Strategy balance not increase after rent expiry"
//         );
//     }

//     function testDepositOf() public {
//         uint256 initialDeposit = arbiterHook.depositOf(
//             Currency.unwrap(currency0),
//             user1
//         );
//         assertEq(initialDeposit, 0, "Initial deposit should be zero");

//         transferToUser1AndDepositAs(10_000e18);

//         uint256 postDeposit = arbiterHook.depositOf(
//             Currency.unwrap(currency0),
//             user1
//         );
//         assertEq(
//             postDeposit,
//             10_000e18,
//             "Deposit amount does not match expected value"
//         );
//     }

//     function testBiddingCurrency() public {
//         address expectedCurrency = Currency.unwrap(currency0);
//         address actualCurrency = arbiterHook.biddingCurrency(key);
//         assertEq(
//             actualCurrency,
//             expectedCurrency,
//             "Bidding currency does not match expected value"
//         );
//     }

//     function testActiveStrategySameBlockAsOverbid() public {
//         address initialStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             initialStrategy,
//             address(0),
//             "Initial active strategy should be address(0)"
//         );

//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);

//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         // Trigger _payRent
//         addLiquidity(key, 1, 1, -60, 60, address(this));

//         address activeStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             address(0),
//             activeStrategy,
//             "Active strategy was updated unexpectedly"
//         );
//     }

//     function testActiveStrategy() public {
//         address initialStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             initialStrategy,
//             address(0),
//             "Initial active strategy should be address(0)"
//         );

//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);

//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         moveBlockBy(1);

//         // Trigger _payRent
//         addLiquidity(key, 1, 1, -60, 60, address(this));

//         address updatedStrategy = arbiterHook.activeStrategy(key);
//         assertEq(
//             updatedStrategy,
//             address(strategy),
//             "Active strategy was not updated correctly"
//         );
//     }

//     function testWinnerStrategy() public {
//         address initialWinnerStrategy = arbiterHook.winnerStrategy(key);
//         assertEq(
//             initialWinnerStrategy,
//             address(0),
//             "Initial winner strategy should be address(0)"
//         );

//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         address currentWinnerStrategy = arbiterHook.winnerStrategy(key);
//         assertEq(
//             currentWinnerStrategy,
//             address(strategy),
//             "Winner strategy was not set correctly"
//         );
//     }

//     function testWinner() public {
//         address initialWinner = arbiterHook.winner(key);
//         assertEq(
//             initialWinner,
//             address(0),
//             "Initial winner should be address(0)"
//         );

//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);

//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         address currentWinner = arbiterHook.winner(key);
//         assertEq(currentWinner, user1, "Winner was not set correctly");
//     }

//     function testRentPerBlock() public {
//         AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
//         uint96 initialRentPerBlock = slot1.rentPerBlock();
//         assertEq(initialRentPerBlock, 0, "Initial rentPerBlock should be zero");

//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);
//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);

//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         slot1 = arbiterHook.poolSlot1(id);
//         uint96 rentPerBlockBeforePayment = slot1.rentPerBlock();
//         assertEq(
//             rentPerBlockBeforePayment,
//             10e18,
//             "rentPerBlock should not update until rent is paid"
//         );

//         uint128 amountIn = 1e18;
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         slot1 = arbiterHook.poolSlot1(id);
//         uint96 updatedRentPerBlock = slot1.rentPerBlock();
//         assertEq(
//             updatedRentPerBlock,
//             10e18,
//             "rentPerBlock was not updated correctly"
//         );
//     }

//     function testRentEndBlock() public {
//         AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
//         uint64 initialRentEndBlock = slot1.rentEndBlock();
//         assertEq(
//             initialRentEndBlock,
//             STARTING_BLOCK,
//             "When no rent is being paid out, initial rentEndBlock should be equal to the latest add liqudity's block"
//         );

//         uint32 desiredRentEndBlock = uint32(
//             block.number + DEFAULT_MINIMUM_RENT_BLOCKS
//         );
//         console.log("current block", block.number);
//         console.log("desiredRentEndBlock", desiredRentEndBlock);
//         MockStrategy strategy = new MockStrategy(DEFAULT_MAX_POOL_SWAP_FEE);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(key, 10e18, desiredRentEndBlock, address(strategy));
//         vm.stopPrank();

//         slot1 = arbiterHook.poolSlot1(id);
//         uint64 currentRentEndBlock = slot1.rentEndBlock();
//         console.log("current block", block.number);
//         console.log("currentRentEndBlock", currentRentEndBlock);
//         assertEq(
//             currentRentEndBlock,
//             desiredRentEndBlock,
//             "rentEndBlock was not set correctly"
//         );
//     }

//     function testExactOutZeroForOne() public {
//         uint24 fee = 1000;
//         MockStrategy strategy = new MockStrategy(fee);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         uint128 amountOut = 1e18;
//         exactOutputSingle(
//             ICLRouterBase.CLSwapExactOutputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountOut: amountOut,
//                 amountInMaximum: 2e18,
//                 hookData: ZERO_BYTES
//             })
//         );
//     }
//     function testExactOutOneForZero() public {
//         uint24 fee = 1000;
//         MockStrategy strategy = new MockStrategy(fee);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         uint128 amountOut = 1e18;
//         exactOutputSingle(
//             ICLRouterBase.CLSwapExactOutputSingleParams({
//                 poolKey: key,
//                 zeroForOne: false,
//                 amountOut: amountOut,
//                 amountInMaximum: 2e18,
//                 hookData: ZERO_BYTES
//             })
//         );
//     }

//     function testExactInZeroForOne() public {
//         uint24 fee = 1000;
//         MockStrategy strategy = new MockStrategy(fee);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         uint128 amountIn = 1e18;

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );
//     }

//     function testExactInOneForZero() public {
//         uint24 fee = 1000;
//         MockStrategy strategy = new MockStrategy(fee);

//         transferToUser1AndDepositAs(10_000e18);

//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();

//         uint128 amountIn = 1e18;

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: false,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );
//     }

//     function testWinnerCanChangeFeeAndSwapReflects() public {
//         uint24 initialFee = 1000;
//         uint24 updatedFee = 2000;
//         MockStrategy strategy = new MockStrategy(initialFee);

//         transferToUser1AndDepositAs(10_000e18);
//         vm.startPrank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(strategy)
//         );
//         vm.stopPrank();
//         moveBlockBy(1);

//         strategy.setFee(updatedFee);

//         // Perform a swap
//         uint128 amountIn = 1e18;

//         uint256 feeAmount = (amountIn * updatedFee) / 1e6;
//         uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
//             127;

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         // Assert
//         uint256 strategyBalance = vault.balanceOf(
//             address(strategy),
//             key.currency1
//         );
//         assertEq(
//             strategyBalance,
//             expectedFeeAmount,
//             "Strategy balance should reflect updated fee"
//         );
//     }

//     /// test executing 3 swaps, after each checks remainingRent decreasing appropriately (calling via remainingRent)
//     function testRemainingRentDecreases() public {
//         // User1 deposits currency0
//         transferToUser1AndDepositAs(10_000e18);

//         // User1 overbids
//         vm.prank(user1);
//         arbiterHook.overbid(
//             key,
//             10e18,
//             uint32(block.number + DEFAULT_MINIMUM_RENT_BLOCKS),
//             address(0)
//         );

//         moveBlockBy(10);

//         // 1st swap
//         uint128 amountIn = 1e18;

//         uint128 expectedDonate = 10e18 * 10;
//         vm.expectEmit(true, true, true, true);
//         emit ICLPoolManager.Donate(
//             key.toId(),
//             address(arbiterHook),
//             expectedDonate,
//             0,
//             0
//         );

//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         // Check remaining rent
//         AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
//         uint128 remainingRent = slot1.remainingRent();
//         assertLt(
//             remainingRent,
//             1000e18,
//             "Remaining rent should be less than initial deposit"
//         );

//         console.log("[testRemainingRentDecreases] init rent", uint256(1000e18));
//         console.log(
//             "[testRemainingRentDecreases] remaining rent",
//             remainingRent
//         );

//         // 2nd swap
//         moveBlockBy(10);
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         // Check remaining rent
//         slot1 = arbiterHook.poolSlot1(id);
//         uint128 remainingRent2 = slot1.remainingRent();
//         assertEq(
//             remainingRent2,
//             remainingRent - expectedDonate,
//             "Remaining rent should be less than previous remaining rent 1"
//         );

//         console.log(
//             "[testRemainingRentDecreases] remaining rent 1",
//             remainingRent2
//         );

//         // 3rd swap
//         moveBlockBy(10);
//         exactInputSingle(
//             ICLRouterBase.CLSwapExactInputSingleParams({
//                 poolKey: key,
//                 zeroForOne: true,
//                 amountIn: amountIn,
//                 amountOutMinimum: 0,
//                 hookData: ZERO_BYTES
//             })
//         );

//         // Check remaining rent
//         slot1 = arbiterHook.poolSlot1(id);
//         uint128 remainingRent3 = slot1.remainingRent();
//         assertEq(
//             remainingRent3,
//             remainingRent2 - expectedDonate,
//             "Remaining rent should be less than previous remaining rent 2"
//         );
//     }
// }
