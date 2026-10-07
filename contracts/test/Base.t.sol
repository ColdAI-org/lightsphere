// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LightsphereAnchor} from "../src/LightsphereAnchor.sol";
import {LightsphereTypes as T} from "../src/LightsphereTypes.sol";
import {MockHTS, MockHAS, MockToken} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    address internal constant HBAR = address(0);
    uint64 internal constant MIN_CHALLENGE = 1 hours;

    MockHTS internal hts;
    MockHAS internal has;
    MockToken internal token;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal carolPk = 0xCA201;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public virtual {
        vm.etch(address(0x167), type(MockHTS).runtimeCode);
        vm.etch(address(0x16a), type(MockHAS).runtimeCode);
        hts = MockHTS(address(0x167));
        has = MockHAS(address(0x16a));
        token = new MockToken();
        hts.register(address(token), false);
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        carol = vm.addr(carolPk);
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _state(bytes32 sphereId, uint64 version, uint256[] memory balances, bool isFinal)
        internal
        pure
        returns (T.SphereState memory)
    {
        return T.SphereState(sphereId, version, balances, keccak256(abi.encode("app", version)), isFinal);
    }

    function _u(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory x) {
        x = new uint256[](4);
        (x[0], x[1], x[2], x[3]) = (a, b, c, d);
    }

    function _signAll(LightsphereAnchor anchor, T.SphereState memory s, uint256[] memory pks)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = anchor.stateDigest(s);
        sigs = new bytes[](pks.length);
        for (uint256 i; i < pks.length; ++i) {
            sigs[i] = _sig(pks[i], digest);
        }
    }
}
