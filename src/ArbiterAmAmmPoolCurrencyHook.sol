// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ArbiterAmAmmBaseHook} from "./ArbiterAmAmmBaseHook.sol";

/// @notice ArbiterAmAmmBaseHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The strategy address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The strategy address should be able to manage ERC6909 claim tokens in the PoolManager.
///
/// @notice ArbiterAmAmmPoolCurrencyHook uses currency0 or currency1 from the pool ( depending on immutable RENT_IN_TOKEN_ZERO ) as the rent currency.
/// @notice The rent is distributed to the active tick using donate.
contract ArbiterAmAmmPoolCurrencyHook is ArbiterAmAmmBaseHook {
    bool immutable RENT_IN_TOKEN_ZERO;

    using LPFeeLibrary for uint24;

    constructor(
        ICLPoolManager poolManager_,
        bool rentInTokenZero_,
        address initOwner_
    ) ArbiterAmAmmBaseHook(poolManager_, initOwner_) {
        RENT_IN_TOKEN_ZERO = rentInTokenZero_;
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////// ArbiterAmAmmBase Internal Overrides /////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////
    function _getPoolRentCurrency(
        PoolKey memory key
    ) internal view override returns (Currency) {
        Currency currency = RENT_IN_TOKEN_ZERO ? key.currency0 : key.currency1;

        return currency;
    }

    function _distributeRent(
        PoolKey memory key,
        uint128 rentAmount
    ) internal override {
        vault.burn(address(this), _getPoolRentCurrency(key), rentAmount);
        poolManager.donate(key, rentAmount, 0, "");
    }
}
