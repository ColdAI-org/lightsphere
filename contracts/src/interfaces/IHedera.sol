// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @dev Hedera Account Service system contract (HIP-632) at 0x16a.
interface IHederaAccountService {
    function isAuthorizedRaw(address account, bytes memory messageHash, bytes memory signature)
        external
        returns (bool);
}

/// @dev The subset of the Hedera Token Service system contract (0x167) the anchor uses.
///      Called with low-level calls so the anchor also runs against plain ERC-20 tokens.
interface IHederaTokenServiceLite {
    function associateToken(address account, address token) external returns (int64 responseCode);
    function getTokenCustomFees(address token) external returns (int64 responseCode);
}

library HederaResponseCodes {
    int64 internal constant SUCCESS = 22;
    int64 internal constant TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT = 194;
}
