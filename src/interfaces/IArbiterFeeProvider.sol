// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";

interface IArbiterFeeProvider {
    /// @return The fee for the swap
    /// @dev Must cost less than GET_SWAP_FEE_GAS_LIMIT
    /// @param sender The address of the swap sender
    /// @param key The key of the pool to swap in
    /// @param params The swap parameters
    /// @param hookData The hook data
    function getSwapFee(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (uint24);
}
