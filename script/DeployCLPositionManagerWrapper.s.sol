// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {CLPositionManagerWrapper} from "../src/periphery/CLPositionManagerWrapper.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

contract DeployCLPositionManagerWrapperScript is Script {
    function setUp() public {}

    function run() public {
        vm.createSelectFork("bsc-testnet");
        vm.startBroadcast();
        CLPositionManagerWrapper deployedContract = new CLPositionManagerWrapper(
                ICLPositionManager(0xFdFf31FdAD716cbcc27B84e8dECd81b2087E8775)
            );

        vm.stopBroadcast();
    }
}
