// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {LightsphereTypes} from "../LightsphereTypes.sol";

/// @notice Anchor contract interface from the Lightsphere HIP (signed mode and shared functions).
interface ILightsphereAnchor {
    enum Status {
        NONE,
        FUNDING,
        OPEN,
        CLOSING,
        SETTLED,
        REFUNDED,
        HALTED
    }

    event SphereOpened(bytes32 indexed sphereId, LightsphereTypes.SphereParams params);
    event SphereFunded(bytes32 indexed sphereId, address indexed participant);
    event SphereActive(bytes32 indexed sphereId);
    event StateCheckpointed(bytes32 indexed sphereId, uint64 version, bytes32 appDataHash);
    event CloseStarted(bytes32 indexed sphereId, uint64 version, uint64 challengeEndsAt);
    event SphereSettled(bytes32 indexed sphereId, uint64 version, bytes32 appDataHash);
    event SphereRefunded(bytes32 indexed sphereId);
    event Withdrawn(address indexed account, address indexed asset, uint256 amount);

    function open(LightsphereTypes.SphereParams calldata params) external returns (bytes32 sphereId);
    function fund(bytes32 sphereId, bytes calldata joinSig) external payable;
    function reclaimFunding(bytes32 sphereId) external;
    function closeCooperative(LightsphereTypes.SphereState calldata state, bytes[] calldata sigs) external;
    function checkpoint(LightsphereTypes.SphereState calldata state, bytes[] calldata sigs) external;
    function startClose(bytes32 sphereId, LightsphereTypes.SphereState calldata state, bytes[] calldata sigs) external;
    function finalizeClose(bytes32 sphereId) external;
    function withdraw(address asset) external;
    function withdrawTo(address asset, address to) external;

    function status(bytes32 sphereId) external view returns (Status);
    function latestState(bytes32 sphereId) external view returns (uint64 version, bytes32 appDataHash);
    function claimable(address account, address asset) external view returns (uint256);
}

/// @notice Network-mode additions.
interface ILightsphereNetworkAnchor is ILightsphereAnchor {
    event DepositSent(
        bytes32 indexed sphereId, uint64 depositId, address indexed recipient, address asset, uint256 amount
    );
    event DepositRefunded(bytes32 indexed sphereId, uint64 depositId);
    event WithdrawalReceived(
        bytes32 indexed sphereId,
        uint64 withdrawalId,
        uint64 sphereEpoch,
        address indexed account,
        address indexed recipient,
        address asset,
        uint256 amount
    );
    event WithdrawalReleased(bytes32 indexed sphereId, uint64 withdrawalId);
    event CheckpointAccepted(
        bytes32 indexed sphereId, uint64 sphereEpoch, bytes32 balancesRoot, uint64 lastAppliedDepositId
    );
    event SphereHalted(bytes32 indexed sphereId, uint64 lastSphereEpoch);
    event Exited(bytes32 indexed sphereId, address indexed account, address indexed asset, uint256 amount);

    function depositToSphere(bytes32 sphereId, address asset, uint256 amount, address recipient) external payable;
    function releaseWithdrawal(bytes32 sphereId, uint64 withdrawalId) external;
    function declareHalt(bytes32 sphereId) external;
    function exit(
        bytes32 sphereId,
        address asset,
        uint256 balance,
        uint256 cumDepositsApplied,
        uint256 cumWithdrawalsInitiated,
        bytes32[] calldata proof
    ) external;
    function exitWithoutLeaf(bytes32 sphereId, address asset) external;
}
