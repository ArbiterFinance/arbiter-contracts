// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCLSwapRouter} from "../pool-cl/helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "../pool-cl/helpers/MockCLPositionManager.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ICLPositionDescriptor} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {CLPositionDescriptorOffChain} from "pancake-v4-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {CLTestUtils} from "../pool-cl/utils/CLTestUtils.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RewardTracker} from "../../src/RewardTracker.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {CLBaseHook} from "../../src/pool-cl/CLBaseHook.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolExtension} from "../../src/libraries/PoolExtension.sol";
import {PositionExtension} from "../../src/libraries/PositionExtension.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "pancake-v4-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";

/// @title NoOpRewardTracker
/// @notice This contract is used to test the RewardTracker abstrat contract
/// @dev does not implement any additional logic besides stub functions for collecting & accruing rewards

contract NoOpRewardTracker is CLBaseHook, RewardTracker {
    using CLPoolParametersHelper for bytes32;
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using CLPositionInfoLibrary for CLPositionInfo;

    constructor(
        ICLPoolManager _poolManager,
        ICLPositionManager _positionManager
    ) CLBaseHook(_poolManager) RewardTracker(_positionManager) {}

    function getHooksRegistrationBitmap()
        external
        pure
        virtual
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: true,
                    afterInitialize: false,
                    beforeAddLiquidity: false,
                    beforeRemoveLiquidity: false,
                    afterAddLiquidity: false,
                    afterRemoveLiquidity: false,
                    beforeSwap: false,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: false,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: false,
                    afterRemoveLiquidityReturnsDelta: false
                })
            );
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(poolId);
        _initialize(poolId, tick);

        return this.beforeInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        _handleActiveTickChange(poolId, tick, key.parameters.getTickSpacing());

        return (this.afterSwap.selector, 0);
    }

    function _beforeOnSubscribeTracker(
        PoolKey memory key
    ) internal virtual override {
        // some logic
    }
    function _beforeOnUnubscribeTracker(
        PoolKey memory key
    ) internal virtual override {
        // some logic
    }
    function _beforeOnModifyLiquidityTracker(
        PoolKey memory key
    ) internal override {
        // some logic
    }

    function _beforeOnTransferTracker(PoolKey memory key) internal override {
        // some logic
    }
    function donateRewards(PoolId poolId, uint128 amount) public {
        _distributeReward(poolId, amount);
    }

    function accrueRewards(uint256 tokenId) public {
        (PoolKey memory poolKey, CLPositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(
                positionInfo.tickLower(),
                positionInfo.tickUpper()
            )
        );
    }

    function collectRewards(address to) external returns (uint256 rewards) {
        rewards = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;
    }
}