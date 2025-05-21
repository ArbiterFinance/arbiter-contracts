// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLSlot0, CLSlot0Library} from "infinity-core/src/pool-cl/types/CLSlot0.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

contract ArbiterFeeProvider is IArbiterFeeProvider {
    using PoolIdLibrary for PoolKey;

    ICLPoolManager public immutable poolManager;
    address private immutable arbiter;

    constructor(ICLPoolManager _poolManager, address _arbiter) {
        poolManager = _poolManager;
        arbiter = _arbiter;
    }

    function getPoolTxVolumeInToken0(
        PoolId poolId
    ) internal returns (uint256 token0Amount) {
        assembly {
            token0Amount := tload(poolId)
        }
    }

    function setPoolTxVolumeInToken0(
        PoolId poolId,
        uint256 token0Amount
    ) internal {
        assembly {
            tstore(poolId, token0Amount)
        }
    }

    function getSwapFee(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) external returns (uint24) {
        if (msg.sender == arbiter) {
            return 0;
        }

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , )= poolManager.getSlot0(poolId);

        uint256 swapVolumeInToken0;
        if (params.zeroForOne){
            if (params.amountSpecified >=0) {
                swapVolumeInToken0 = uint256(params.amountSpecified);
            } else {
                swapVolumeInToken0 = FullMath.mulDiv(
                    uint256(-params.amountSpecified),
                    1 << 96,
                    sqrtPriceX96
                );
            }
        } else {
            if (params.amountSpecified >=0) {
                swapVolumeInToken0 = FullMath.mulDiv(
                    uint256(params.amountSpecified),
                    sqrtPriceX96,
                    1 << 96
                );
            } else {
                swapVolumeInToken0 = uint256(-params.amountSpecified);
            }
        }
        
        uint256 token0Volume = getPoolTxVolumeInToken0(poolId) + swapVolumeInToken0;
        setPoolTxVolumeInToken0(poolId, token0Volume);

        uint128 liquidity = poolManager.getLiquidity(poolId);  

        // volume needed to change price by 0.01%
        uint256 volumeStep = (uint256(liquidity) << 96)/sqrtPriceX96 /20001;

        // 1e12 = 100%, for each volumeStep, 0.01% fee
        uint256 fee = token0Volume / volumeStep * 1e8;
        uint256 feeBefore = (token0Volume - swapVolumeInToken0) / volumeStep * 1e8;

        uint256 expectedTotalFeeInToken0 = token0Volume * fee / 1e12;
        uint256 estimatedPaidFeeInToken0 = (token0Volume - swapVolumeInToken0) * feeBefore / 1e12;

        uint256 feeToBePaid = expectedTotalFeeInToken0 - estimatedPaidFeeInToken0;

        uint256 feeU256 = feeToBePaid * 1e6 / swapVolumeInToken0;

        if (feeU256 > 1e6) {
            feeU256 = 1e6;
        }

        return uint24(feeU256); 
    }
}
