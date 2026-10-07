// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @notice Shared types and encodings from the Lightsphere HIP.
library LightsphereTypes {
    uint8 internal constant MODE_SIGNED = 0;
    uint8 internal constant MODE_NETWORK = 1;

    uint8 internal constant MSG_DEPOSIT = 1;
    uint8 internal constant MSG_WITHDRAW = 2;
    uint8 internal constant MSG_CHECKPOINT = 3;

    uint256 internal constant MAX_PARTICIPANTS = 16;
    uint256 internal constant MAX_ASSETS = 8;
    uint64 internal constant MAX_CHALLENGE_PERIOD = 30 days;

    bytes32 internal constant JOIN_SPHERE_TYPEHASH = keccak256("JoinSphere(bytes32 sphereId,address participant)");

    bytes32 internal constant SPHERE_STATE_TYPEHASH =
        keccak256("SphereState(bytes32 sphereId,uint64 version,uint256[] balances,bytes32 appDataHash,bool isFinal)");

    struct SphereParams {
        uint8 mode;
        address[] participants; // accounts that fund, start a close and receive payouts
        address[] signers; // secp256k1 signing addresses, one per participant; states are signed with these
        address[] assets;
        uint256[] initialDeposits;
        uint64 challengePeriod;
        uint64 fundingDeadline;
        bytes networkConfig;
        bytes32 salt;
    }

    struct SphereState {
        bytes32 sphereId;
        uint64 version;
        uint256[] balances;
        bytes32 appDataHash;
        bool isFinal;
    }

    struct NetworkConfig {
        string sphereLedgerId;
        bytes32 channelId;
        bytes32 connectorId;
        address gateway;
        uint64 checkpointInterval;
        uint64 haltTimeout;
    }

    function hashState(SphereState calldata s) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SPHERE_STATE_TYPEHASH,
                s.sphereId,
                s.version,
                keccak256(abi.encodePacked(s.balances)),
                s.appDataHash,
                s.isFinal
            )
        );
    }

    /// @dev Double-hashed so a 64-byte internal node can never be passed off as a leaf.
    function leafHash(
        address account,
        address asset,
        uint256 balance,
        uint256 cumulativeDepositsApplied,
        uint256 cumulativeWithdrawalsInitiated
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(account, asset, balance, cumulativeDepositsApplied, cumulativeWithdrawalsInitiated)
                )
            )
        );
    }
}
