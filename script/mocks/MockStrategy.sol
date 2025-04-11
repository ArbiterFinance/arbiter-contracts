import {IArbiterFeeProvider} from "src/interfaces/IArbiterFeeProvider.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

contract MockStrategy is IArbiterFeeProvider {
    uint24 public fee;

    constructor(uint24 _fee) {
        fee = _fee;
    }

    function getSwapFee(
        address,
        PoolKey calldata,
        ICLPoolManager.SwapParams calldata,
        bytes calldata
    ) external view returns (uint24) {
        return fee;
    }

    function setFee(uint24 _fee) external {
        fee = _fee;
    }
}
