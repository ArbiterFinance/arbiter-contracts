// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCLSwapRouter} from "./pool-cl/helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./pool-cl/helpers/MockCLPositionManager.sol";
import {IArbiterFeeProvider} from "../src/interfaces/IArbiterFeeProvider.sol";
import {IArbiterAmAmmHarbergerLease} from "../src/interfaces/IArbiterAmAmmHarbergerLease.sol";
import {ArbiterAmAmmSimpleHook} from "../src/ArbiterAmAmmSimpleHook.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ICLPositionDescriptor} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {CLPositionDescriptorOffChain} from "pancake-v4-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {CLTestUtils} from "./pool-cl/utils/CLTestUtils.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";

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

contract ArbiterAmAmmSimpleHookTest is Test, CLTestUtils {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    uint24 constant DEFAULT_SWAP_FEE = 300;
    uint24 constant MAX_FEE = 10000;
    bytes constant ZERO_BYTES = bytes("");

    MockCLSwapRouter swapRouter;

    ArbiterAmAmmSimpleHook arbiterHook;

    MockERC20 weth;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    address user1 = address(0x1111111111111111111111111111111111111111);
    address user2 = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        (currency0, currency1) = deployContractsWithTokens();

        // Deploy the arbiter hook with required parameters
        arbiterHook = new ArbiterAmAmmSimpleHook(
            ICLPoolManager(address(poolManager)),
            10, // MINIMUM_RENT_TIME_IN_BLOCKS
            1000000, // RENT_FACTOR (100%)
            5, // TRANSTION_BLOCKS
            50000, // GET_SWAP_FEE_GAS_LIMIT
            true // RENT_IN_TOKEN_ZERO
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

        // Initialize the pool with a price of 1:1
        poolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(
            address(this),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).mint(
            address(this),
            type(uint256).max
        );
        // Add liquidity
        addLiquidity(key, 10 ether, 10 ether, -60, 60, address(this));

        console.log("currency0: ", address(Currency.unwrap(currency0)));
        console.log("currency1: ", address(Currency.unwrap(currency1)));
        console.log("user1", user1);
        // console.log("user2", user2);
        console.log("this", address(this));
        console.log("vault", address(vault));
        console.log("universalRouter", address(universalRouter));
        console.log("arbiterHook", address(arbiterHook));
    }

    function transferToUser1AndDepositAs(uint256 amount) public {
        currency0.transfer(user1, amount);
        vm.startPrank(user1);
        IERC20(Currency.unwrap(currency0)).approve(
            address(arbiterHook),
            amount
        );
        arbiterHook.deposit(Currency.unwrap(currency0), amount);
        vm.stopPrank();
    }

    function testBiddingAndRentPayment() public {
        transferToUser1AndDepositAs(1000e18);

        // User1 overbids
        vm.prank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(0) // strategy (none)
        );

        address winner = arbiterHook.winner(key);
        assertEq(winner, user1, "Winner should be user1 after overbidding");

        // Simulate some blocks passing
        vm.roll(block.number + 5);

        (uint128 remainingRent, , , , ) = arbiterHook.rentDatas(id);
        assertLt(
            remainingRent,
            1000e18,
            "Remaining rent should be less than initial deposit"
        );

        // add liquidity
        addLiquidity(key, 1, 1, -60, 60, address(this));

        // TODO: test rent payment
    }

    function testStrategyContractSetsFee() public {
        // Deploy a mock strategy that sets swap fee to MAX_FEE
        MockStrategy strategy = new MockStrategy(MAX_FEE);

        // User1 deposits and overbids with the strategy
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        uint128 amountIn = 1e18;

        permit2Approve(address(this), currency0, address(universalRouter));
        permit2Approve(address(this), currency1, address(universalRouter));

        IERC20(Currency.unwrap(currency0)).approve(
            address(universalRouter),
            1000e18
        );

        IERC20(Currency.unwrap(currency1)).approve(
            address(universalRouter),
            1000e18
        );

        permit2Approve(address(this), currency0, address(vault));
        permit2Approve(address(this), currency1, address(vault));

        IERC20(Currency.unwrap(currency0)).approve(address(vault), 1000e18);

        IERC20(Currency.unwrap(currency1)).approve(address(vault), 1000e18);

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 postBalance0 = key.currency0.balanceOf(address(this));
        uint256 postBalance1 = key.currency1.balanceOf(address(this));

        uint256 expectedFeeAmount = (amountIn * MAX_FEE) / 1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        assertEq(
            poolManager.protocolFeesAccrued(key.currency0),
            0,
            "Protocol fees accrued in currency0 should be zero"
        );
        assertEq(
            poolManager.protocolFeesAccrued(key.currency0),
            0,
            "Protocol fees accrued in currency0 should be zero"
        );

        uint256 strategyBalance = vault.balanceOf(
            address(strategy),
            key.currency1
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance does not match expected fee amount"
        );
    }

    function testStrategyFeeCappedAtMaxFee() public {
        // Deploy a mock strategy that sets swap fee to a value greater than MAX_FEE
        uint24 strategyFee = MAX_FEE + 1000; // Fee greater than MAX_FEE
        MockStrategy strategy = new MockStrategy(strategyFee);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        // Perform a swap
        uint128 amountIn = 1e18;
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(this));
        uint256 postBalance1 = key.currency1.balanceOf(address(this));

        uint256 expectedFeeAmount = (amountIn * MAX_FEE) / 1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = vault.balanceOf(
            address(strategy),
            key.currency1
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance should match expected fee amount"
        );
    }

    function testDepositAndWithdraw() public {
        // User1 deposits currency0

        transferToUser1AndDepositAs(100e18);

        uint256 depositBalance = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            depositBalance,
            100e18,
            "Deposit amount does not match expected value"
        );

        // User1 withdraws half
        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);

        depositBalance = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            depositBalance,
            50e18,
            "Deposit balance should be 50e18 after withdrawing half"
        );

        // withdraws the rest
        arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);
        depositBalance = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            depositBalance,
            0,
            "Deposit balance should be zero after withdrawing all"
        );

        vm.stopPrank();
    }

    function testChangeStrategy() public {
        // User1 overbids and becomes the winner
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint48(block.number + 20), address(0));
        vm.stopPrank();

        // User1 changes strategy
        MockStrategy newStrategy = new MockStrategy(5000);
        vm.prank(user1);
        arbiterHook.changeStrategy(key, address(newStrategy));

        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            currentStrategy,
            address(newStrategy),
            "Active strategy should be updated to new strategy"
        );
    }

    function testRevertIfNotDynamicFee() public {
        PoolKey memory nonDynamicKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: arbiterHook,
            poolManager: poolManager,
            fee: DEFAULT_SWAP_FEE,
            parameters: bytes32(
                uint256(arbiterHook.getHooksRegistrationBitmap())
            ).setTickSpacing(60)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(arbiterHook),
                abi.encodeWithSelector(
                    IArbiterAmAmmHarbergerLease.NotDynamicFee.selector
                )
            )
        );
        poolManager.initialize(nonDynamicKey, Constants.SQRT_RATIO_1_1);
    }

    function testRentTooLow() public {
        // User1 deposits currency0
        transferToUser1AndDepositAs(1000e18);

        vm.prank(user1);
        arbiterHook.overbid(key, 1e18, uint48(block.number + 20), address(0));
        vm.expectRevert(IArbiterAmAmmHarbergerLease.RentTooLow.selector);
        arbiterHook.overbid(key, 1e18, uint48(block.number + 20), address(0));
    }

    function testNotWinnerCannotChangeStrategy() public {
        // User1 overbids and becomes the winner
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint48(block.number + 20), address(0));
        vm.stopPrank();

        // User2 tries to change strategy
        vm.prank(user2);
        vm.expectRevert(IArbiterAmAmmHarbergerLease.CallerNotWinner.selector);
        arbiterHook.changeStrategy(key, address(0));
    }

    function testDefaultFeeWhenNoOneHasWon() public {
        // Ensure there is no winner and no strategy set
        address currentWinner = arbiterHook.winner(key);
        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            currentWinner,
            address(0),
            "Initial winner should be address(0)"
        );
        assertEq(
            currentStrategy,
            address(0),
            "Initial strategy should be address(0)"
        );

        uint128 amountIn = 1e18;
        currency0.transfer(user1, 1000e18);

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(user1));
        uint256 prevBalance1 = key.currency1.balanceOf(address(user1));

        assertEq(prevBalance0, 1000e18, "Initial balance0 mismatch");
        assertEq(prevBalance1, 0, "Initial balance1 mismatch");

        // Perform a swap
        permit2Approve(user1, currency0, address(universalRouter));
        vm.startPrank(user1);
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );
        vm.stopPrank();

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(user1));
        uint256 postBalance1 = key.currency1.balanceOf(address(user1));

        // Calculate the expected fee using DEFAULT_SWAP_FEE
        uint256 expectedFeeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = vault.balanceOf(
            address(currentStrategy),
            key.currency1
        );
        assertEq(
            strategyBalance,
            0,
            "Strategy balance should be zero when no one has won"
        );
    }

    function testDefaultFeeAfterAuctionWinExpired() public {
        // Deploy a mock strategy that sets swap fee to MAX_FEE
        MockStrategy strategy = new MockStrategy(MAX_FEE);

        // User1 deposits and overbids with the strategy
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);

        // Set rent to expire in 20 blocks
        uint48 rentEndBlock = uint48(block.number + 20);
        arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategy));
        vm.stopPrank();

        vm.roll(block.number + 21);

        uint48 currentBlock = uint48(block.number);
        uint48 rentEndBlockFromContract = arbiterHook.rentEndBlock(key);
        assertTrue(currentBlock > rentEndBlockFromContract);

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        // Perform a swap
        uint128 amountIn = 1e18;
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        //trigger _payRent
        console.log("triggering _payRent");
        addLiquidity(key, 1, 1, -60, 60, address(this));

        address currentWinner = arbiterHook.winner(key);
        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            currentWinner,
            address(0),
            "Winner should be reset to address(0) after rent expiry"
        );
        assertEq(
            currentStrategy,
            address(0),
            "Strategy should be reset to address(0) after rent expiry"
        );

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(this));
        uint256 postBalance1 = key.currency1.balanceOf(address(this));

        uint256 expectedFeeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;

        console.log("prevBalance0: ", prevBalance0);
        console.log("postBalance0: ", postBalance0);
        console.log("amountIn: ", amountIn);
        console.log("expectedFeeAmount: ", expectedFeeAmount);

        assertApproxEqRel(
            prevBalance0 - postBalance0,
            amountIn,
            1,
            "Amount in mismatch"
        );

        uint256 expectedPoolToken0Increase = amountIn - expectedFeeAmount;

        uint256 strategyBalance = vault.balanceOf(
            address(currentStrategy),
            key.currency1
        );
        assertEq(
            strategyBalance,
            0,
            "Strategy balance should be zero after rent expiry"
        );
    }

    function testDepositOf() public {
        uint256 initialDeposit = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(initialDeposit, 0, "Initial deposit should be zero");

        transferToUser1AndDepositAs(1000e18);

        uint256 postDeposit = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            postDeposit,
            1000e18,
            "Deposit amount does not match expected value"
        );
    }

    function testBiddingCurrency() public {
        address expectedCurrency = Currency.unwrap(currency0);
        address actualCurrency = arbiterHook.biddingCurrency(key);
        assertEq(
            actualCurrency,
            expectedCurrency,
            "Bidding currency does not match expected value"
        );
    }

    function testActiveStrategy() public {
        address initialStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            initialStrategy,
            address(0),
            "Initial active strategy should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(MAX_FEE);
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        // Trigger _payRent
        addLiquidity(key, 1, 1, -60, 60, address(this));

        address updatedStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            updatedStrategy,
            address(strategy),
            "Active strategy was not updated correctly"
        );
    }

    function testWinnerStrategy() public {
        address initialWinnerStrategy = arbiterHook.winnerStrategy(key);
        assertEq(
            initialWinnerStrategy,
            address(0),
            "Initial winner strategy should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(MAX_FEE);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        address currentWinnerStrategy = arbiterHook.winnerStrategy(key);
        assertEq(
            currentWinnerStrategy,
            address(strategy),
            "Winner strategy was not set correctly"
        );
    }

    function testWinner() public {
        address initialWinner = arbiterHook.winner(key);
        assertEq(
            initialWinner,
            address(0),
            "Initial winner should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(MAX_FEE);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user1, "Winner was not set correctly");
    }

    function testRentPerBlock() public {
        uint96 initialRentPerBlock = arbiterHook.rentPerBlock(key);
        assertEq(initialRentPerBlock, 0, "Initial rentPerBlock should be zero");

        MockStrategy strategy = new MockStrategy(MAX_FEE);
        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint96 rentPerBlockBeforePayment = arbiterHook.rentPerBlock(key);
        assertEq(
            rentPerBlockBeforePayment,
            10e18,
            "rentPerBlock should not update until rent is paid"
        );

        uint128 amountIn = 1e18;
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint96 updatedRentPerBlock = arbiterHook.rentPerBlock(key);
        assertEq(
            updatedRentPerBlock,
            10e18,
            "rentPerBlock was not updated correctly"
        );
    }

    function testRentEndBlock() public {
        uint48 initialRentEndBlock = arbiterHook.rentEndBlock(key);
        assertEq(initialRentEndBlock, 0, "Initial rentEndBlock should be zero");

        uint48 desiredRentEndBlock = uint48(block.number + 20);
        MockStrategy strategy = new MockStrategy(MAX_FEE);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, desiredRentEndBlock, address(strategy));
        vm.stopPrank();

        uint48 currentRentEndBlock = arbiterHook.rentEndBlock(key);
        assertEq(
            currentRentEndBlock,
            desiredRentEndBlock,
            "rentEndBlock was not set correctly"
        );
    }

    function testExactOutZeroForOne() public {
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountOut = 1e18;
        exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountOut: amountOut,
                amountInMaximum: 2e18,
                hookData: ZERO_BYTES
            })
        );
    }
    function testExactOutOneForZero() public {
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountOut = 1e18;
        exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountOut: amountOut,
                amountInMaximum: 2e18,
                hookData: ZERO_BYTES
            })
        );
    }

    function testExactInZeroForOne() public {
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountIn = 1e18;

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );
    }

    function testExactInOneForZero() public {
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToUser1AndDepositAs(1000e18);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountIn = 1e18;

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );
    }

    function testWinnerCanChangeFeeAndSwapReflects() public {
        uint24 initialFee = 1000;
        uint24 updatedFee = 2000;
        MockStrategy strategy = new MockStrategy(initialFee);

        transferToUser1AndDepositAs(1000e18);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint48(block.number + 20),
            address(strategy)
        );
        vm.stopPrank();

        strategy.setFee(updatedFee);

        // Perform a swap
        uint128 amountIn = 1e18;
        uint128 expectedFeeAmount = (amountIn * updatedFee) / 1e6;

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        // Assert
        uint256 strategyBalance = vault.balanceOf(
            address(strategy),
            key.currency1
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance should reflect updated fee"
        );
    }

    /// test executing 3 swaps, after each checks remainingRent decreasing appropriately (calling via remainingRent)
    function testRemainingRentDecreases() public {
        // User1 deposits currency0
        transferToUser1AndDepositAs(1000e18);

        // User1 overbids
        vm.prank(user1);
        console.log("current block", block.number);
        console.log("rent end block", uint48(block.number + 50));
        arbiterHook.overbid(key, 10e18, uint48(block.number + 50), address(0));

        vm.roll(block.number + 10);

        // 1st swap
        uint128 amountIn = 1e18;

        uint128 expectedDonate = 10e18 * 10;
        // vm.expectEmit(true, true, false, true);
        // vm.expectEmit();
        // emit ICLPoolManager.Donate(
        //     key.toId(),
        //     address(universalRouter),
        //     expectedDonate,
        //     0,
        //     0
        // );

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        // Check remaining rent
        (uint128 remainingRent, , , , ) = arbiterHook.rentDatas(id);
        assertLt(
            remainingRent,
            1000e18,
            "Remaining rent should be less than initial deposit"
        );

        // 2nd swap
        vm.roll(block.number + 20);
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        // Check remaining rent
        (uint128 remainingRent2, , , , ) = arbiterHook.rentDatas(id);
        assertLt(
            remainingRent2,
            remainingRent,
            "Remaining rent should be less than previous remaining rent 1"
        );

        // assertEq(1000e18, remainingRent - expectedDonate, "Remaining rent should be 1000e18");

        // 3rd swap
        vm.roll(block.number + 30);
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        // Check remaining rent
        (uint128 remainingRent3, , , , ) = arbiterHook.rentDatas(id);
        assertLt(
            remainingRent3,
            remainingRent2,
            "Remaining rent should be less than previous remaining rent 2"
        );
    }
}