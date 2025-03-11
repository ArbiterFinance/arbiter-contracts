// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IArbiterFeeProvider} from "./IArbiterFeeProvider.sol";

interface IArbiterAmmStrategy is IArbiterFeeProvider {
    /// @notice Collects fees from the PoolManager
    /// @param key The key of the pool to collect fees from
    function collectFees(PoolKey calldata key) external;
}
