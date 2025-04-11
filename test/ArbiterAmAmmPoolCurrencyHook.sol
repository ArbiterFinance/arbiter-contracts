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
import {IArbiterFeeProvider} from "../src/interfaces/IArbiterFeeProvider.sol";
import {IArbiterAmAmmHarbergerLease} from "../src/interfaces/IArbiterAmAmmHarbergerLease.sol";
import {ArbiterAmAmmPoolCurrencyHook} from "../src/ArbiterAmAmmPoolCurrencyHook.sol";
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
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

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

contract ArbiterAmAmmPoolCurrencyHookTest is Test, CLTestUtils {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;
    using AuctionSlot0Library for AuctionSlot0;
    using AuctionSlot1Library for AuctionSlot1;

    uint24 constant DEFAULT_SWAP_FEE = 300;
    bytes constant ZERO_BYTES = bytes("");
    uint256 constant STARTING_BLOCK = 10000000;
    uint256 CURRENT_BLOCK_NUMBER = 10000000;

    uint32 internal DEFAULT_TRANSITION_BLOCKS = 30;
    uint32 internal DEFAULT_MINIMUM_RENT_BLOCKS = 300;
    uint24 internal DEFAULT_OVERBID_FACTOR = 2e4; // 2%
    uint24 internal DEFAULT_WINNER_FEE_SHARE = 5e4;
    uint24 constant DEFAULT_POOL_SWAP_FEE = 50000; // 5%

    MockCLSwapRouter swapRouter;

    ArbiterAmAmmPoolCurrencyHook arbiterHook;

    MockERC20 weth;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    address user1 = address(0x1111111111111111111111111111111111111111);
    address user2 = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        vm.roll(STARTING_BLOCK);
        (currency0, currency1) = deployContractsWithTokens();

        // Deploy the arbiter hook with required parameters
        arbiterHook = new ArbiterAmAmmPoolCurrencyHook(
            ICLPoolManager(address(poolManager)),
            true, // RENT_IN_TOKEN_ZERO
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
        id = key.toId();

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
    }

    function transferToAndDepositAs(uint256 amount, address user) public {
        currency0.transfer(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(
            address(arbiterHook),
            amount
        );
        arbiterHook.deposit(Currency.unwrap(currency0), amount);
        vm.stopPrank();
    }

    function resetCurrentBlock() public {
        CURRENT_BLOCK_NUMBER = STARTING_BLOCK;
    }

    function moveBlockBy(uint256 interval) public {
        CURRENT_BLOCK_NUMBER += interval;
        vm.roll(CURRENT_BLOCK_NUMBER);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_BiddingAndRentPayment() public {
        resetCurrentBlock();
        transferToAndDepositAs(10_000e18, user1);
        //offset blocks
        moveBlockBy(100);

        // User1 overbids
        vm.prank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + 100 + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0) // strategy (none)
        );
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 startingRent = slot1.remainingRent();

        address winner = arbiterHook.winner(key);
        assertEq(winner, user1, "Winner should be user1 after overbidding");

        moveBlockBy(5);
        addLiquidity(key, 1, 1, -60, 60, address(this));

        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent = slot1.remainingRent();
        assertEq(
            startingRent - remainingRent,
            5 * 10e18,
            "Remaining rent should be less than initial deposit"
        );

        // add liquidity
        addLiquidity(key, 1, 1, -60, 60, address(this));

        // TODO: test rent payment
    }

    function test_ArbiterAmAmmPoolCurrencyHook_StrategyContractSetsFee()
        public
    {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        // User1 deposits and overbids with the strategy
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        uint128 amountIn = 1e18;
        moveBlockBy(1);

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

        uint256 feeAmount = (amountIn * DEFAULT_POOL_SWAP_FEE) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
            1e6;

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
            key.currency0
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance does not match expected fee amount"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_StrategyFeeCappedAtMaxFee()
        public
    {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to a value greater than DEFAULT_POOL_SWAP_FEE
        uint24 strategyFee = 1e6 + 1000; // Fee greater than DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(strategyFee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        moveBlockBy(1);
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

        uint256 feeAmount = (amountIn * 400) / 1e6; //capped at 1e6 (100%) - if exceeds it reverts to default fee
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
            1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = vault.balanceOf(
            address(strategy),
            key.currency0
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance should match expected fee amount"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DepositAndWithdraw() public {
        resetCurrentBlock();
        // User1 deposits currency0

        transferToAndDepositAs(100e18, user1);

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

    function test_ArbiterAmAmmPoolCurrencyHook_ChangeStrategy() public {
        resetCurrentBlock();
        // User1 overbids and becomes the winner
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0)
        );
        vm.stopPrank();

        // User1 changes strategy
        MockStrategy newStrategy = new MockStrategy(5000);
        vm.prank(user1);
        arbiterHook.changeStrategy(key, address(newStrategy));
        moveBlockBy(1);

        addLiquidity(key, 1, 1, -60, 60, address(this));

        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            currentStrategy,
            address(newStrategy),
            "Active strategy should be updated to new strategy"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RevertIfNotDynamicFee() public {
        resetCurrentBlock();
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
                CustomRevert.WrappedError.selector,
                address(arbiterHook),
                ICLHooks.afterInitialize.selector,
                abi.encodeWithSelector(
                    IArbiterAmAmmHarbergerLease.NotDynamicFee.selector
                ),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(nonDynamicKey, Constants.SQRT_RATIO_1_1);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentTooLow() public {
        resetCurrentBlock();
        // User1 deposits currency0
        transferToAndDepositAs(10_000e18, user1);

        vm.prank(user1);
        arbiterHook.overbid(
            key,
            1e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0)
        );
        vm.expectRevert(IArbiterAmAmmHarbergerLease.RentTooLow.selector);
        arbiterHook.overbid(
            key,
            1e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0)
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_NotWinnerCannotChangeStrategy()
        public
    {
        resetCurrentBlock();
        // User1 overbids and becomes the winner
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0)
        );
        vm.stopPrank();

        // User2 tries to change strategy
        vm.prank(user2);
        vm.expectRevert(IArbiterAmAmmHarbergerLease.CallerNotWinner.selector);
        arbiterHook.changeStrategy(key, address(0));
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DefaultFeeWhenNoOneHasWon()
        public
    {
        resetCurrentBlock();
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
        uint256 feeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
            1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = vault.balanceOf(
            address(currentStrategy),
            key.currency0
        );
        assertEq(
            strategyBalance,
            0,
            "Strategy balance should be zero when no one has won"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DefaultFeeAfterAuctionWinExpired()
        public
    {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        // User1 deposits and overbids with the strategy
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        // Set rent to expire in 300 blocks
        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );
        arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

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
        moveBlockBy(DEFAULT_MINIMUM_RENT_BLOCKS - 1);

        uint32 currentBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint64 rentEndBlockFromContract = slot1.rentEndBlock();
        assertEq(
            currentBlock,
            rentEndBlockFromContract,
            "currentBlock vs rent end block mismatch"
        );

        moveBlockBy(1);

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        // Perform a swap
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 strategyBalance = vault.balanceOf(
            address(strategy),
            key.currency0
        );

        assertGt(
            strategyBalance,
            0,
            "Strategy balance should be greater than zero after rent expiry"
        );

        moveBlockBy(1);

        //trigger _payRent
        addLiquidity(key, 1, 1, -60, 60, address(this));

        address currentWinner = arbiterHook.winner(key);
        assertEq(
            currentWinner,
            address(0),
            "Winner should be reset to address(0) after rent expiry"
        );

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(this));
        uint256 postBalance1 = key.currency1.balanceOf(address(this));

        uint256 feeAmount = (amountIn * DEFAULT_SWAP_FEE) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
            1e6;

        uint256 strategyBalancePostExpiry = vault.balanceOf(
            address(strategy),
            key.currency0
        );
        assertEq(
            strategyBalancePostExpiry,
            strategyBalance,
            "Strategy balance not increase after rent expiry"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DepositOf() public {
        resetCurrentBlock();
        uint256 initialDeposit = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(initialDeposit, 0, "Initial deposit should be zero");

        transferToAndDepositAs(10_000e18, user1);

        uint256 postDeposit = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            postDeposit,
            10_000e18,
            "Deposit amount does not match expected value"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_BiddingCurrency() public {
        resetCurrentBlock();
        address expectedCurrency = Currency.unwrap(currency0);
        address actualCurrency = arbiterHook.biddingCurrency(key);
        assertEq(
            actualCurrency,
            expectedCurrency,
            "Bidding currency does not match expected value"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ActiveStrategySameBlockAsOverbid()
        public
    {
        resetCurrentBlock();
        address initialStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            initialStrategy,
            address(0),
            "Initial active strategy should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        // Trigger _payRent
        addLiquidity(key, 1, 1, -60, 60, address(this));

        address activeStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            address(0),
            activeStrategy,
            "Active strategy was updated unexpectedly"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ActiveStrategyDifferentBlock()
        public
    {
        resetCurrentBlock();
        address initialStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            initialStrategy,
            address(0),
            "Initial active strategy should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        moveBlockBy(1);

        // Trigger _payRent
        addLiquidity(key, 1, 1, -60, 60, address(this));

        address updatedStrategy = arbiterHook.activeStrategy(key);
        assertEq(
            updatedStrategy,
            address(strategy),
            "Active strategy was not updated correctly"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_WinnerStrategy() public {
        resetCurrentBlock();
        address initialWinnerStrategy = arbiterHook.winnerStrategy(key);
        assertEq(
            initialWinnerStrategy,
            address(0),
            "Initial winner strategy should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
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

    function test_ArbiterAmAmmPoolCurrencyHook_Winner() public {
        resetCurrentBlock();
        address initialWinner = arbiterHook.winner(key);
        assertEq(
            initialWinner,
            address(0),
            "Initial winner should be address(0)"
        );

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user1, "Winner was not set correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentPerBlock() public {
        resetCurrentBlock();
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint96 initialRentPerBlock = slot1.rentPerBlock();
        assertEq(initialRentPerBlock, 0, "Initial rentPerBlock should be zero");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        slot1 = arbiterHook.poolSlot1(id);
        uint96 rentPerBlockBeforePayment = slot1.rentPerBlock();
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

        slot1 = arbiterHook.poolSlot1(id);
        uint96 updatedRentPerBlock = slot1.rentPerBlock();
        assertEq(
            updatedRentPerBlock,
            10e18,
            "rentPerBlock was not updated correctly"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentEndBlock() public {
        resetCurrentBlock();
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint64 initialRentEndBlock = slot1.rentEndBlock();
        assertEq(
            initialRentEndBlock,
            STARTING_BLOCK,
            "When no rent is being paid out, initial rentEndBlock should be equal to the latest add liqudity's block"
        );

        uint32 desiredRentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, desiredRentEndBlock, address(strategy));
        vm.stopPrank();

        slot1 = arbiterHook.poolSlot1(id);
        uint64 currentRentEndBlock = slot1.rentEndBlock();
        assertEq(
            currentRentEndBlock,
            desiredRentEndBlock,
            "rentEndBlock was not set correctly"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ExactOutZeroForOne() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();
        moveBlockBy(1);

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
    function test_ArbiterAmAmmPoolCurrencyHook_ExactOutOneForZero() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();
        moveBlockBy(1);

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

    function test_ArbiterAmAmmPoolCurrencyHook_ExactInZeroForOne() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountIn = 1e18;
        moveBlockBy(1);
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

    function test_ArbiterAmAmmPoolCurrencyHook_ExactInOneForZero() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();
        moveBlockBy(1);

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

    function test_ArbiterAmAmmPoolCurrencyHook_WinnerCanChangeFeeAndSwapReflects()
        public
    {
        resetCurrentBlock();
        uint24 initialFee = 1000;
        uint24 updatedFee = 2000;
        MockStrategy strategy = new MockStrategy(initialFee);

        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();
        moveBlockBy(1);

        strategy.setFee(updatedFee);

        // Perform a swap
        uint128 amountIn = 1e18;

        uint256 feeAmount = (amountIn * updatedFee) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) /
            1e6;

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
            key.currency0
        );
        assertEq(
            strategyBalance,
            expectedFeeAmount,
            "Strategy balance should reflect updated fee"
        );
    }

    /// test executing 3 swaps, after each checks remainingRent decreasing appropriately (calling via remainingRent)
    function test_ArbiterAmAmmPoolCurrencyHook_RemainingRentDecreases() public {
        resetCurrentBlock();
        transferToAndDepositAs(10_000e18, user1);

        // User1 overbids
        vm.prank(user1);

        moveBlockBy(1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + 1 + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0)
        );

        moveBlockBy(10);
        // 1st swap
        uint128 amountIn = 1e18;

        uint128 expectedDonate = 10e18 * 10;
        vm.expectEmit(true, true, true, false);
        emit ICLPoolManager.Donate(
            key.toId(),
            address(arbiterHook),
            expectedDonate,
            0,
            0
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

        // Check remaining rent
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent = slot1.remainingRent();
        assertLt(
            remainingRent,
            10_000e18,
            "Remaining rent should be less than initial deposit"
        );

        // 2nd swap
        moveBlockBy(10);
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
        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent2 = slot1.remainingRent();
        assertEq(
            remainingRent2,
            remainingRent - expectedDonate,
            "Remaining rent should be less than previous remaining rent 1"
        );

        // 3rd swap
        moveBlockBy(10);
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
        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent3 = slot1.remainingRent();
        assertEq(
            remainingRent3,
            remainingRent2 - expectedDonate,
            "Remaining rent should be less than previous remaining rent 2"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_MultipleSwapsSameBlock() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(strategy)
        );
        vm.stopPrank();

        uint128 amountIn = 1e18;
        moveBlockBy(1);
        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
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
    }

    function test_ArbiterAmAmmPoolCurrencyHook_OverbidAndSwapSameBlock()
        public
    {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS),
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

    function test_ArbiterAmAmmPoolCurrencyHook_OverbidMultipleBids() public {
        resetCurrentBlock();
        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 500;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategyUser1));
        vm.stopPrank();
        moveBlockBy(1);

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

        transferToAndDepositAs(20_000e18, user2);

        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            11e18,
            rentEndBlock + 100,
            address(strategyUser2)
        );
        vm.stopPrank();
        moveBlockBy(1);

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

        uint256 strategyUser1BalanceAfter = vault.balanceOf(
            address(strategyUser1),
            key.currency0
        );
        assertEq(
            strategyUser1BalanceAfter,
            strategyUser1Balance,
            "User1 strategy unexpectedly earned additional fees after losing the auction"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_AuctionFeeDepositRequirement()
        public
    {
        resetCurrentBlock();

        arbiterHook.setAuctionFee(key, 500);

        uint80 rentPerBlock = 10e18;
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);

        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");
        uint128 totalRent = rentPerBlock * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 auctionFee = (totalRent * hookAuctionFee) / 1e6;
        uint128 requiredDeposit = totalRent + auctionFee;

        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferToAndDepositAs(totalRent, user1);

        vm.prank(user1);
        vm.expectRevert(
            IArbiterAmAmmHarbergerLease.InsufficientDeposit.selector
        );
        arbiterHook.overbid(key, rentPerBlock, rentEndBlock, address(0));

        transferToAndDepositAs(auctionFee, user1);

        vm.prank(user1);
        arbiterHook.overbid(key, rentPerBlock, rentEndBlock, address(0));

        address winner = arbiterHook.winner(key);
        assertEq(
            winner,
            user1,
            "User1 should be the winner after depositing the full required amount"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_TwoUsersOverbidSameBlock()
        public
    {
        resetCurrentBlock();
        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 2000;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        uint80 user1Rent = 10e18;
        uint80 user1Deposit = user1Rent * DEFAULT_MINIMUM_RENT_BLOCKS;

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);

        transferToAndDepositAs(user1Deposit, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            user1Rent,
            rentEndBlock,
            address(strategyUser1)
        );
        vm.stopPrank();

        uint80 user2Rent = 20e18;
        transferToAndDepositAs(user2Rent * DEFAULT_MINIMUM_RENT_BLOCKS, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            user2Rent,
            rentEndBlock,
            address(strategyUser2)
        );
        vm.stopPrank();

        address winner = arbiterHook.winner(key);
        assertEq(
            winner,
            user2,
            "User2 should be the winner after the higher overbid in the same block"
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

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 *
            DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser2Balance = vault.balanceOf(
            address(strategyUser2),
            key.currency0
        );

        assertEq(
            strategyUser2Balance,
            0,
            "Strategy user2 did receive fees in the same block as the overbid"
        );

        moveBlockBy(1);

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        uint256 strategyUser2Balance2 = vault.balanceOf(
            address(strategyUser2),
            key.currency0
        );
        assertEq(
            strategyUser2Balance2,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive the correct fees after winning"
        );

        uint256 user1DepositBefore = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            user1DepositBefore,
            user1Deposit,
            "User1's deposit should still be intact"
        );

        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1Deposit);
        vm.stopPrank();

        uint256 user1DepositAfter = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            user1DepositAfter,
            0,
            "User1 should be able to withdraw their full deposit after losing"
        );

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);

        assertEq(
            user1BalancePreDeposit,
            user1BalancePostWithdraw,
            "User1 should have their deposit returned to their wallet"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_TwoUsersOverbidSameBlockWithAuctionFee()
        public
    {
        resetCurrentBlock();

        arbiterHook.setAuctionFee(key, 500);

        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);

        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");

        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 2000;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(
            STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        uint80 user1Rent = 10e18;
        uint128 user1TotalRent = user1Rent * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6;
        uint128 user1Deposit = user1TotalRent + user1AuctionFee;

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);

        transferToAndDepositAs(user1Deposit, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            user1Rent,
            rentEndBlock,
            address(strategyUser1)
        );
        vm.stopPrank();

        uint80 user2Rent = 20e18;
        uint128 user2TotalRent = user2Rent * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6;
        uint128 user2Deposit = user2TotalRent + user2AuctionFee;

        transferToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            user2Rent,
            rentEndBlock,
            address(strategyUser2)
        );
        vm.stopPrank();

        address winner = arbiterHook.winner(key);
        assertEq(
            winner,
            user2,
            "User2 should be the winner after the higher overbid in the same block"
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

        uint256 strategyUser2Balance = vault.balanceOf(
            address(strategyUser2),
            key.currency0
        );
        assertEq(
            strategyUser2Balance,
            0,
            "Strategy user2 did receive fees in the same block as the overbid"
        );

        moveBlockBy(1);

        exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            })
        );

        (
            uint128 initialRemainingRent,
            uint128 feeLocked,
            uint128 collectedFee
        ) = arbiterHook.auctionFees(id);
        assertEq(
            feeLocked,
            user2AuctionFee,
            "Auction fee should be collected for user2"
        );

        assertEq(
            initialRemainingRent,
            user2TotalRent,
            "Initial remaining rent should be equal to user2's total rent"
        );

        assertEq(
            collectedFee,
            0,
            "Collected fee should be zero before the swap"
        );

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 *
            DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser2Balance2 = vault.balanceOf(
            address(strategyUser2),
            key.currency0
        );
        assertEq(
            strategyUser2Balance2,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive the correct fees after winning"
        );

        uint256 user1DepositBefore = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            user1DepositBefore,
            user1Deposit,
            "User1's deposit should still be intact"
        );

        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1Deposit);
        vm.stopPrank();

        uint256 user1DepositAfter = arbiterHook.depositOf(
            Currency.unwrap(currency0),
            user1
        );
        assertEq(
            user1DepositAfter,
            0,
            "User1 should be able to withdraw their full deposit after losing"
        );

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);

        assertEq(
            user1BalancePreDeposit,
            user1BalancePostWithdraw,
            "User1 should have their deposit returned to their wallet"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ComplexAuctionScenario() public {
        // Scenario:
        // 1. Set an auction fee.
        // 2. User1 deposits and overbids, becoming the winner.
        // 3. After 10 blocks, perform a swap -> User1 pays rent for 10 blocks, User1 strategy collects fees.
        // 4. User2 deposits and overbids with a higher rent in a new block, becoming the new winner.
        //    Upon takeover, User1 gets refunded remaining rent + a portion of the previously locked fee (feeRefund).
        // 5. After another 10 blocks, perform a second swap -> User2 pays rent for 10 blocks, User2 strategy collects fees.
        // 6. User1, who is no longer the winner, can now withdraw their remaining deposit, including refunded rent and fee portion.
        // 7. Verify protocol fee distribution and that User1 ends up with the correct refunded amounts.

        resetCurrentBlock();

        // Set auction fee to 500 (0.05%)
        arbiterHook.setAuctionFee(key, 500);
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
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
            DEFAULT_MINIMUM_RENT_BLOCKS; // 10e18 * 300 = 3000e18
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6; // (3000e18 * 500)/1e6 = 1.5e18
        uint128 user1Deposit = user1TotalRent + user1AuctionFee; // 3000e18 + 1.5e18 = 3001.5e18

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);
        transferToAndDepositAs(user1Deposit, user1);

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
            .poolSlot1(id)
            .remainingRent();

        assertEq(
            remainingRentAfterSwapUser1,
            user1TotalRent - 10 * user1RentPerBlock,
            "Remaining rent should be less than user1's total rent after first swap"
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
            DEFAULT_MINIMUM_RENT_BLOCKS; // 20e18 * 300 = 6000e18
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6; // (6000e18 * 500)/1e6 = 3e18
        uint128 user2Deposit = user2TotalRent + user2AuctionFee; // 6000e18 + 3e18 = 6003e18

        uint32 rentEndBlock2 = uint32(
            STARTING_BLOCK + 10 + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            user2RentPerBlock,
            rentEndBlock2,
            address(strategyUser2)
        );
        vm.stopPrank();

        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRentAfterUser2Overbid = slot1.remainingRent();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user2, "User2 should be the new winner");

        (
            uint128 initialRemainingRent,
            uint128 feeLocked,
            uint128 collectedFee
        ) = arbiterHook.auctionFees(id);
        assertEq(
            feeLocked,
            user2AuctionFee,
            "Auction fee should be collected for user2"
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
            "Collected fee should be greater than zero after user2 overbid - user1 fee refund but part of it got captured"
        );

        moveBlockBy(10);

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

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);
        assertTrue(
            user1BalancePostWithdraw >= user1BalancePreDeposit,
            "User1 should end up with at least their initial balance (including refunds)"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_CollectFeeAcrossSwaps() public {
        // Scenario:
        // 1. Set an auction fee.
        // 2. User1 deposits and overbids, becoming the winner.
        // 3. After 10 blocks, perform a swap -> User1 pays rent for 10 blocks, User1 strategy collects fees.
        // 4. User2 deposits and overbids with a higher rent in a new block, becoming the new winner.
        //    Upon takeover, User1 gets refunded remaining rent + a portion of the previously locked fee (feeRefund).
        // 5. After another 10 blocks, perform a second swap -> User2 pays rent for 10 blocks, User2 strategy collects fees.
        // 6. User1, who is no longer the winner, can now withdraw their remaining deposit, including refunded rent and fee portion.
        // 7. Verify protocol fee distribution and that User1 ends up with the correct refunded amounts.

        resetCurrentBlock();

        // Set auction fee to 500 (0.05%)
        arbiterHook.setAuctionFee(key, 500);
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
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
            DEFAULT_MINIMUM_RENT_BLOCKS; // 10e18 * 300 = 3000e18
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6; // (3000e18 * 500)/1e6 = 1.5e18
        uint128 user1Deposit = user1TotalRent + user1AuctionFee; // 3000e18 + 1.5e18 = 3001.5e18

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);
        transferToAndDepositAs(user1Deposit, user1);

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
            .poolSlot1(id)
            .remainingRent();

        assertEq(
            remainingRentAfterSwapUser1,
            user1TotalRent - 10 * user1RentPerBlock,
            "Remaining rent should be less than user1's total rent after first swap"
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
            DEFAULT_MINIMUM_RENT_BLOCKS; // 20e18 * 300 = 6000e18
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6; // (6000e18 * 500)/1e6 = 3e18
        uint128 user2Deposit = user2TotalRent + user2AuctionFee; // 6000e18 + 3e18 = 6003e18

        uint32 rentEndBlock2 = uint32(
            STARTING_BLOCK + 10 + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(
            key,
            user2RentPerBlock,
            rentEndBlock2,
            address(strategyUser2)
        );
        vm.stopPrank();

        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRentAfterUser2Overbid = slot1.remainingRent();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user2, "User2 should be the new winner");

        (
            uint128 initialRemainingRent,
            uint128 feeLocked,
            uint128 collectedFee
        ) = arbiterHook.auctionFees(id);
        assertEq(
            feeLocked,
            user2AuctionFee,
            "Auction fee should be collected for user2"
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
            "Collected fee should be greater than zero after user2 overbid - user1 fee refund but part of it got captured"
        );
        moveBlockBy(100);

        transferToAndDepositAs(user2Deposit * 1000000, user1);
        uint32 user1RentEndBlock2 = uint32(
            STARTING_BLOCK + 10 + 100 + DEFAULT_MINIMUM_RENT_BLOCKS
        );
        uint128 user1RentPerBlock2 = user2RentPerBlock * 100;

        uint128 user1TotalRent2 = user2RentPerBlock *
            100 *
            (DEFAULT_MINIMUM_RENT_BLOCKS);
        uint128 user1AuctionFee2 = (user1TotalRent2 * hookAuctionFee) / 1e6;

        uint128 user2RemainingRentBeforeUser1Overbids2 = arbiterHook
            .poolSlot1(id)
            .remainingRent();

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            uint80(user1RentPerBlock2),
            user1RentEndBlock2,
            address(strategyUser1)
        );
        vm.stopPrank();

        moveBlockBy(10);

        (
            uint128 initialRemainingRent2,
            uint128 feeLocked2,
            uint128 collectedFee2
        ) = arbiterHook.auctionFees(id);

        uint128 rentFromBlocksPassed = 100 * user2RentPerBlock;

        uint128 feeRefund2 = uint128(
            (uint256(user2AuctionFee) *
                (user2RemainingRentBeforeUser1Overbids2 -
                    rentFromBlocksPassed)) / user2TotalRent
        );

        assertEq(
            collectedFee2,
            collectedFee + (user2AuctionFee - feeRefund2),
            "The fee should be collected for user1 after the second overbid"
        );
    }
    function test_ArbiterAmAmmPoolCurrencyHook_OverbidMultipleBids_RemainingRentCalculation()
        public
    {
        // Scenario:
        // 1. Set an auction fee.
        // 2. User1 deposits and overbids, becoming the winner.
        // 3. After 10 blocks, User2 deposits & performs an overbid -> User1 pays rent for 10 blocks, User1 strategy collects fees.
        // User2 becomes the new winner. Upon takeover, User1 gets refunded remaining rent + a portion of the previously locked fee (feeRefund).
        // The fee collected by the hook should be calculated accordingly.

        resetCurrentBlock();

        // Set auction fee to 500 (0.05%)
        uint24 auctionFee = 500;
        arbiterHook.setAuctionFee(key, 500);

        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
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

        // User1
        uint80 user1RentPerBlock = 10e18;
        uint128 user1TotalRent = user1RentPerBlock *
            DEFAULT_MINIMUM_RENT_BLOCKS; // 10e18 * 300 = 3000e18
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6; // (3000e18 * 500)/1e6 = 1.5e18
        uint128 user1Deposit = user1TotalRent + user1AuctionFee; // 3000e18 + 1.5e18 = 3001.5e18

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);
        transferToAndDepositAs(user1Deposit, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(
            key,
            user1RentPerBlock,
            rentEndBlock,
            address(strategyUser1)
        );
        vm.stopPrank();

        moveBlockBy(10);

        uint80 user2RentPerBlock = 20e18;
        uint128 user2TotalRent = user2RentPerBlock *
            DEFAULT_MINIMUM_RENT_BLOCKS; // 20e18 * 300 = 6000e18
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6; // (6000e18 * 500)/1e6 = 3e18
        uint128 user2Deposit = user2TotalRent + user2AuctionFee; // 6000e18 + 3e18 = 6003e18

        uint32 rentEndBlock2 = uint32(
            STARTING_BLOCK + 10 + DEFAULT_MINIMUM_RENT_BLOCKS
        );

        transferToAndDepositAs(user2Deposit, user2);
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

        (, , uint128 collectedFee) = arbiterHook.auctionFees(id);

        uint128 expectedFeePaidOnOverbidByUser1 = ((user1RentPerBlock * 10) *
            auctionFee) / 1e6;

        assertEq(
            collectedFee,
            expectedFeePaidOnOverbidByUser1,
            "Collected fee should calculated accordingly after user2 overbid - user1 fee refund but part of it got captured"
        );
    }
}
