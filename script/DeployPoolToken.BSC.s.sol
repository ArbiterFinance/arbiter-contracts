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

contract DeployPoolTokenBSC is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    Vault vault = Vault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager clPoolManager =
        ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    ICLPositionManager clPositionManager =
        ICLPositionManager(0x55f4c8abA71A1e923edC303eb4fEfF14608cC226);
    IAllowanceTransfer permit2 =
        IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);

    address deployer;

    function setUp() public {
        deployer = vm.envAddress("ADDRESS");
        console.log("Deployer address: ", deployer);
    }

    function run() public {
        vm.createSelectFork("bsc");
        vm.startBroadcast();

        // Deploy the arbiter hook with required parameters
        bool rentInTokenZero = true;
        ArbiterAmAmmPoolCurrencyHook arbiterHook = new ArbiterAmAmmPoolCurrencyHook(
                ICLPoolManager(address(clPoolManager)),
                rentInTokenZero,
                address(0xfa206DAB60c014bEb6833004D8848910165e6047)
            );

        console.log("rentInTokenZero: ", rentInTokenZero);
        console.log("Arbiter Hook address: ", address(arbiterHook));

        vm.stopBroadcast();
    }
}
