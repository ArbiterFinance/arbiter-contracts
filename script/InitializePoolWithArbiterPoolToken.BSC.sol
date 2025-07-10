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
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract InitializePoolWithArbiterPoolToken is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    ICLPoolManager clPoolManager =
        ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    ArbiterAmAmmPoolCurrencyHook arbiterHook =
        ArbiterAmAmmPoolCurrencyHook(
            address(0x1f8a26643752BfE3149E04106E1FD7eCbf78EBC1)
        );

    address token0 = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82); // CAKE
    address token1 = address(0x55d398326f99059fF775485246999027B3197955); // USDT

    int24 internal constant TICK_SPACING = 10;

    address deployer;

    function setUp() public {
        deployer = vm.envAddress("ADDRESS");
        console.log("Deployer address: ", deployer);
    }

    function run() public {
        vm.createSelectFork("bsc");
        vm.startBroadcast();

        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);

        // Ensure the tokens are sorted
        if (address(token0) < address(token1)) {
            // do nothing, already sorted
        } else {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(arbiterHook),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(
                uint256(arbiterHook.getHooksRegistrationBitmap())
            ).setTickSpacing(TICK_SPACING)
        });
        PoolId id = key.toId();

        // uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));

        uint160 sqrtPriceX96 = 117166639856619046214651088228; //2.187

        clPoolManager.initialize(key, sqrtPriceX96);

        console.log("PoolId: ");
        console.logBytes32(keccak256(abi.encode(key)));
        console.log("Arbiter Hook address: ", address(arbiterHook));

        vm.stopBroadcast();
    }
}
