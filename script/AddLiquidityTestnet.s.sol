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

contract AddLiquidityTestnet is Script {
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

        Currency currency0 = Currency.wrap(
            address(0x3b19973ab9E2E8B81d28E908cD8DE31e82f78775)
        );
        Currency currency1 = Currency.wrap(
            address(0xd2d36826446325e8e9C0b40Eea83F24e2eD03aeC)
        );

        ArbiterAmAmmPoolCurrencyHook arbiterHook = ArbiterAmAmmPoolCurrencyHook(
            0x5913DDF47Cbaf92e87365d68FAcFc8C05494d7Cd
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

        // Add liquidity
        addLiquidity(key, 0.2 ether, 0.2 ether, -180, 180, address(deployer));

        vm.stopBroadcast();
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
