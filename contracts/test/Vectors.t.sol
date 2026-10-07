// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Base} from "./Base.t.sol";
import {LightsphereAnchor} from "../src/LightsphereAnchor.sol";
import {ILightsphereAnchor} from "../src/interfaces/ILightsphereAnchor.sol";
import {LightsphereTypes as T} from "../src/LightsphereTypes.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// @notice Checks the contract against vectors produced independently by the Go harness (harness/cmd/lsvectors).
contract VectorsTest is Base {
    using stdJson for string;

    string internal json;

    function setUp() public override {
        super.setUp();
        json = vm.readFile("test/vectors/signed-v1.json");
    }

    function _uints(string memory key) internal view returns (uint256[] memory out) {
        string[] memory raw = json.readStringArray(key);
        out = new uint256[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            out[i] = vm.parseUint(raw[i]);
        }
    }

    function test_goVectorsMatchAndSettle() public {
        vm.chainId(json.readUint(".chainId"));
        address at = json.readAddress(".verifyingContract");
        deployCodeTo("LightsphereAnchor.sol:LightsphereAnchor", abi.encode(address(0xC1A9), uint64(3600)), at);
        LightsphereAnchor anchor = LightsphereAnchor(at);
        assertEq(anchor.domainSeparator(), json.readBytes32(".domainSeparator"), "domain separator");

        T.SphereParams memory p;
        p.mode = T.MODE_SIGNED;
        p.participants = json.readAddressArray(".participants");
        p.assets = json.readAddressArray(".assets");
        p.initialDeposits = _uints(".initialDeposits");
        p.challengePeriod = uint64(json.readUint(".challengePeriod"));
        p.fundingDeadline = uint64(json.readUint(".fundingDeadline"));
        p.salt = json.readBytes32(".salt");
        bytes32 sid = anchor.open(p);
        assertEq(sid, json.readBytes32(".sphereId"), "sphereId");

        // Fund with the token at the vector's asset address.
        vm.etch(p.assets[1], type(MockToken).runtimeCode);
        MockToken tkn = MockToken(p.assets[1]);
        for (uint256 i; i < 2; ++i) {
            address who = p.participants[i];
            vm.deal(who, p.initialDeposits[i * 2]);
            tkn.mint(who, p.initialDeposits[i * 2 + 1]);
            vm.startPrank(who);
            tkn.approve(at, p.initialDeposits[i * 2 + 1]);
            anchor.fund{value: p.initialDeposits[i * 2]}(sid);
            vm.stopPrank();
        }
        assertEq(uint8(anchor.status(sid)), uint8(ILightsphereAnchor.Status.OPEN));

        for (uint256 i;; ++i) {
            string memory k = string.concat(".states[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, k)) break;
            T.SphereState memory s;
            s.sphereId = json.readBytes32(string.concat(k, ".sphereId"));
            s.version = uint64(json.readUint(string.concat(k, ".version")));
            s.balances = _uints(string.concat(k, ".balances"));
            s.appDataHash = json.readBytes32(string.concat(k, ".appDataHash"));
            s.isFinal = json.readBool(string.concat(k, ".isFinal"));
            assertEq(anchor.stateDigest(s), json.readBytes32(string.concat(k, ".digest")), "digest");
            bytes[] memory sigs = json.readBytesArray(string.concat(k, ".signatures"));
            if (s.isFinal) anchor.closeCooperative(s, sigs);
            else anchor.checkpoint(s, sigs);
        }
        assertEq(uint8(anchor.status(sid)), uint8(ILightsphereAnchor.Status.SETTLED));
        assertEq(anchor.claimable(p.participants[1], address(0)), 5e8 + 3e7);
        assertEq(anchor.claimable(p.participants[0], p.assets[1]), 100 + 9);
    }
}
