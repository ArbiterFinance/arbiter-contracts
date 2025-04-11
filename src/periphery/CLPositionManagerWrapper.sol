// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {ICLNotifier} from "infinity-periphery/src/pool-cl/interfaces/ICLNotifier.sol";

contract CLPositionManagerWrapper {
    ICLPositionManager public positionManager;

    constructor(ICLPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function getPositionManager() external view returns (ICLPositionManager) {
        return positionManager;
    }

    // /// @notice Returns the subscriber for a respective position
    // /// @param tokenId the ERC721 tokenId
    // /// @return subscriber the subscriber contract
    // function subscriber(uint256 tokenId) external view returns (ICLSubscriber subscriber);

    // /// @notice Enables the subscriber to receive notifications for a respective position
    // /// @param tokenId the ERC721 tokenId
    // /// @param newSubscriber the address of the subscriber contract
    // /// @param data caller-provided data that's forwarded to the subscriber contract
    // /// @dev Calling subscribe when a position is already subscribed will revert
    // /// @dev payable so it can be multicalled with NATIVE related actions
    // /// @dev will revert if vault is locked
    // function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;

    function subscribeMulti(
        uint256[] calldata tokenIds,
        address newSubscriber,
        bytes calldata data
    ) external payable {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            ICLNotifier(address(positionManager)).subscribe(
                tokenIds[i],
                newSubscriber,
                data
            );
        }
    }

    function hasSubscriber(
        uint256 tokenId
    ) external view returns (bool hasSubscriber) {
        hasSubscriber =
            address(
                ICLNotifier(address(positionManager)).subscriber(tokenId)
            ) !=
            address(0);
    }

    function hasSubscriberMulti(
        uint256[] calldata tokenIds
    ) external view returns (bool[] memory hasSubscriberArray) {
        bool[] memory hasSubscriberArray = new bool[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            hasSubscriberArray[i] = this.hasSubscriber(tokenIds[i]);
        }
    }
}
