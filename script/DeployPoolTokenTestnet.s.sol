// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ArbiterAmAmmPoolCurrencyHook} from "../src/ArbiterAmAmmPoolCurrencyHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {UniversalRouter} from "infinity-universal-router/src/UniversalRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Planner, Plan} from "infinity-periphery/src/libraries/Planner.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Constants} from "infinity-core/test/pool-cl/helpers/Constants.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {Commands} from "infinity-universal-router/src/libraries/Commands.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract DeployPoolTokenTestnet is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    Vault vault = Vault(0x2CdB3EC82EE13d341Dc6E73637BE0Eab79cb79dD);
    ICLPoolManager clPoolManager =
        ICLPoolManager(0x36A12c70c9Cf64f24E89ee132BF93Df2DCD199d4);
    ICLPositionManager clPositionManager =
        ICLPositionManager(0x77DedB52EC6260daC4011313DBEE09616d30d122);
    UniversalRouter universalRouter =
        UniversalRouter(payable(0x87FD5305E6a40F378da124864B2D479c2028BD86));
    IAllowanceTransfer permit2 =
        IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);
    struct PositionConfig {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
    }
    uint24 internal DEFAULT_WINNER_FEE_SHARE = 5e4;
    bytes constant ZERO_BYTES = bytes("");

    address deployer;

    function setUp() public {
        deployer = vm.envAddress("ADDRESS");
        console.log("Deployer address: ", deployer);
    }

    function run() public {
        vm.createSelectFork("bsc-testnet");
        vm.startBroadcast();

        Currency currency0;
        Currency currency1;

        (currency0, currency1) = deployContractsWithTokens();

        // Deploy the arbiter hook with required parameters
        bool rentInTokenZero = true;
        ArbiterAmAmmPoolCurrencyHook arbiterHook = new ArbiterAmAmmPoolCurrencyHook(
                ICLPoolManager(address(clPoolManager)),
                rentInTokenZero,
                address(deployer)
            );

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(arbiterHook),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(
                uint256(arbiterHook.getHooksRegistrationBitmap())
            ).setTickSpacing(60)
        });
        PoolId id = key.toId();

        // Initialize the pool with a price of 1:1
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(
            address(deployer),
            type(uint96).max
        );
        MockERC20(Currency.unwrap(currency1)).mint(
            address(deployer),
            type(uint96).max
        );

        // Add liquidity
        addLiquidity(key, 2 ether, 2 ether, -60, 60, address(deployer));
        addLiquidity(key, 2 ether, 2 ether, -120, 60, address(deployer));
        addLiquidity(key, 2 ether, 2 ether, 60, 120, address(deployer));
        addLiquidity(key, 2 ether, 2 ether, 0, 180, address(deployer));
        addLiquidity(key, 2 ether, 2 ether, -180, 0, address(deployer));

        console.log("PoolId: ");
        console.logBytes32(keccak256(abi.encode(key)));
        console.log("rentInTokenZero: ", rentInTokenZero);

        uint24 strategyFee = 50_000; // 5%
        MockStrategy strategy = new MockStrategy(strategyFee);

        uint256 amount = 10_000e18;
        IERC20(Currency.unwrap(currency0)).approve(
            address(arbiterHook),
            amount
        );
        arbiterHook.deposit(Currency.unwrap(currency0), amount);

        uint128 blocks_per_second = 3;
        uint256 blocks_per_day = 86400 / blocks_per_second;
        uint256 blocks_per_week = blocks_per_day * 7;
        arbiterHook.overbid(
            key,
            10,
            uint32(block.number + blocks_per_week),
            address(strategy)
        );

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

        vm.stopBroadcast();
    }

    function deployContractsWithTokens() internal returns (Currency, Currency) {
        MockERC20 token0 = new MockERC20("token0", "T0", 18);
        MockERC20 token1 = new MockERC20("token1", "T1", 18);

        // approve permit2 contract to transfer our funds
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);

        permit2.approve(
            address(token0),
            address(clPositionManager),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            address(token1),
            address(clPositionManager),
            type(uint160).max,
            type(uint48).max
        );

        permit2.approve(
            address(token0),
            address(universalRouter),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            address(token1),
            address(universalRouter),
            type(uint160).max,
            type(uint48).max
        );

        return SortTokens.sort(token0, token1);
    }

    function addLiquidity(
        PoolKey memory key,
        uint128 amount0Max,
        uint128 amount1Max,
        int24 tickLower,
        int24 tickUpper,
        address recipient
    ) internal returns (uint256 tokenId) {
        tokenId = clPositionManager.nextTokenId();

        console.log("tokenId: ", tokenId);

        (uint160 sqrtPriceX96, , , ) = clPoolManager.getSlot0(key.toId());
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        PositionConfig memory config = PositionConfig({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        Plan memory planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                config,
                liquidity,
                amount0Max,
                amount1Max,
                recipient,
                new bytes(0)
            )
        );
        bytes memory data = planner.finalizeModifyLiquidityWithClose(key);
        clPositionManager.modifyLiquidities(data, block.timestamp + 1000); //TODO
    }

    function exactInputSingle(
        ICLRouterBase.CLSwapExactInputSingleParams memory params
    ) internal {
        Plan memory plan = Planner.init().add(
            Actions.CL_SWAP_EXACT_IN_SINGLE,
            abi.encode(params)
        );
        bytes memory data = params.zeroForOne
            ? plan.finalizeSwap(
                params.poolKey.currency0,
                params.poolKey.currency1,
                ActionConstants.MSG_SENDER
            )
            : plan.finalizeSwap(
                params.poolKey.currency1,
                params.poolKey.currency0,
                ActionConstants.MSG_SENDER
            );

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.INFI_SWAP))
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        universalRouter.execute(commands, inputs);
    }

    function exactOutputSingle(
        ICLRouterBase.CLSwapExactOutputSingleParams memory params
    ) internal {
        Plan memory plan = Planner.init().add(
            Actions.CL_SWAP_EXACT_OUT_SINGLE,
            abi.encode(params)
        );
        bytes memory data = params.zeroForOne
            ? plan.finalizeSwap(
                params.poolKey.currency0,
                params.poolKey.currency1,
                ActionConstants.MSG_SENDER
            )
            : plan.finalizeSwap(
                params.poolKey.currency1,
                params.poolKey.currency0,
                ActionConstants.MSG_SENDER
            );

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.INFI_SWAP))
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        universalRouter.execute(commands, inputs);
    }
}
