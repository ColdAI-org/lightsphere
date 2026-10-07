// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @dev Mirrors LFDT-CLPR clpr-smart-contracts src/interfaces/IClprApplication.sol.
interface IClprApplication {
    function onClprMessage(bytes32 channelId, bytes calldata sender, bytes calldata messageData)
        external
        returns (bytes memory responseData);

    function onClprResponse(bytes32 channelId, uint64 messageId, uint8 status, bytes calldata responseData) external;
}

/// @dev The sendMessage entry point of the CLPR Service (IClprService.sol).
interface IClprServiceSend {
    function sendMessage(
        bytes32 channelId,
        bytes32 connectorId,
        bytes calldata targetApplication,
        bytes calldata messageData
    ) external returns (uint64 messageId);
}

/// @dev ClprTypes.ReplyStatus.SUCCESS
uint8 constant CLPR_REPLY_SUCCESS = 0;
