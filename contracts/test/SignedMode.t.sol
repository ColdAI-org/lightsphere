// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {LightsphereAnchor} from "../src/LightsphereAnchor.sol";
import {ILightsphereAnchor} from "../src/interfaces/ILightsphereAnchor.sol";
import {LightsphereTypes as T} from "../src/LightsphereTypes.sol";
import {FeeOnTransferToken} from "./mocks/Mocks.sol";

contract SignedModeTest is Base {
    LightsphereAnchor internal anchor;
    bytes32 internal sid;
    uint256[] internal pks;

    // Alice: 10 HBAR + 100 MCK, Bob: 5 HBAR + 50 MCK (HBAR in tinybars).
    uint256 internal constant A_H = 10e8;
    uint256 internal constant A_T = 100e18;
    uint256 internal constant B_H = 5e8;
    uint256 internal constant B_T = 50e18;

    function setUp() public override {
        super.setUp();
        anchor = new LightsphereAnchor(address(0xC1A9), MIN_CHALLENGE);
        pks = new uint256[](2);
        (pks[0], pks[1]) = (alicePk, bobPk);
        sid = _openAndFund();
    }

    function _params() internal view returns (T.SphereParams memory p) {
        p.mode = T.MODE_SIGNED;
        p.participants = new address[](2);
        (p.participants[0], p.participants[1]) = (alice, bob);
        p.assets = new address[](2);
        (p.assets[0], p.assets[1]) = (HBAR, address(token));
        p.initialDeposits = _u(A_H, A_T, B_H, B_T);
        p.challengePeriod = MIN_CHALLENGE;
        p.fundingDeadline = uint64(block.timestamp + 1 days);
    }

    function _openAndFund() internal returns (bytes32 id) {
        id = anchor.open(_params());
        vm.deal(alice, A_H);
        vm.deal(bob, B_H);
        token.mint(alice, A_T);
        token.mint(bob, B_T);
        vm.prank(alice);
        token.approve(address(anchor), A_T);
        vm.prank(bob);
        token.approve(address(anchor), B_T);
        vm.prank(alice);
        anchor.fund{value: A_H}(id);
        vm.prank(bob);
        anchor.fund{value: B_H}(id);
    }

    function test_openFundsAndActivates() public view {
        assertEq(uint8(anchor.status(sid)), uint8(ILightsphereAnchor.Status.OPEN));
        assertTrue(hts.associated(address(anchor), address(token)));
        assertEq(anchor.escrow(sid, HBAR), A_H + B_H);
        assertEq(anchor.escrow(sid, address(token)), A_T + B_T);
    }

    function test_cooperativeCloseAndWithdraw() public {
        // Alice pays Bob 2 HBAR and 30 MCK over 1,000 off-ledger updates; only the last one goes on-ledger.
        T.SphereState memory s = _state(sid, 1000, _u(A_H - 2e8, A_T - 30e18, B_H + 2e8, B_T + 30e18), true);
        anchor.closeCooperative(s, _signAll(anchor, s, pks));
        assertEq(uint8(anchor.status(sid)), uint8(ILightsphereAnchor.Status.SETTLED));

        vm.prank(bob);
        anchor.withdraw(HBAR);
        vm.prank(bob);
        anchor.withdraw(address(token));
        assertEq(bob.balance, B_H + 2e8);
        assertEq(token.balanceOf(bob), B_T + 30e18);
        assertEq(anchor.claimable(alice, HBAR), A_H - 2e8);
        assertEq(anchor.escrow(sid, HBAR), 0);
    }

    function test_staleCloseIsReplacedDuringWindow() public {
        T.SphereState memory v3 = _state(sid, 3, _u(A_H, A_T, B_H, B_T), false);
        T.SphereState memory v9 = _state(sid, 9, _u(A_H - 4e8, A_T, B_H + 4e8, B_T), false);
        bytes[] memory sig3 = _signAll(anchor, v3, pks);
        bytes[] memory sig9 = _signAll(anchor, v9, pks);

        // Alice tries to close on an old state that favours her.
        vm.prank(alice);
        anchor.startClose(sid, v3, sig3);
        // A watchtower for Bob (not a participant) submits the newer state.
        vm.prank(address(0x7a7c4));
        anchor.checkpoint(v9, sig9);
        // Replaying the old state now fails.
        vm.expectRevert(LightsphereAnchor.StaleVersion.selector);
        anchor.checkpoint(v3, sig3);

        vm.expectRevert(LightsphereAnchor.WindowOpen.selector);
        anchor.finalizeClose(sid);
        vm.warp(anchor.challengeEndsAt(sid));
        T.SphereState memory v10 = _state(sid, 10, _u(A_H, A_T, B_H, B_T), false);
        bytes[] memory sig10 = _signAll(anchor, v10, pks);
        vm.expectRevert(LightsphereAnchor.WindowClosed.selector);
        anchor.checkpoint(v10, sig10);
        anchor.finalizeClose(sid);
        assertEq(anchor.claimable(bob, HBAR), B_H + 4e8);
        (uint64 version,) = anchor.latestState(sid);
        assertEq(version, 9);
    }

    function test_closeWithNoStateReturnsDeposits() public {
        vm.prank(bob);
        anchor.startClose(sid, _state(sid, 0, new uint256[](0), false), new bytes[](0));
        vm.warp(block.timestamp + MIN_CHALLENGE);
        anchor.finalizeClose(sid);
        assertEq(anchor.claimable(alice, address(token)), A_T);
        assertEq(anchor.claimable(bob, address(token)), B_T);
    }

    function test_rejectsNonParticipantClose() public {
        vm.expectRevert(LightsphereAnchor.NotParticipant.selector);
        vm.prank(carol);
        anchor.startClose(sid, _state(sid, 0, new uint256[](0), false), new bytes[](0));
    }

    function test_rejectsMissingOrWrongSignature() public {
        T.SphereState memory s = _state(sid, 5, _u(A_H, A_T, B_H, B_T), false);
        bytes[] memory sigs = _signAll(anchor, s, pks);
        sigs[1] = _sig(carolPk, anchor.stateDigest(s));
        vm.expectRevert(LightsphereAnchor.BadSignatures.selector);
        anchor.checkpoint(s, sigs);

        bytes[] memory one = new bytes[](1);
        one[0] = _sig(alicePk, anchor.stateDigest(s));
        vm.expectRevert(LightsphereAnchor.BadSignatures.selector);
        anchor.checkpoint(s, one);
    }

    function test_rejectsHighS() public {
        T.SphereState memory s = _state(sid, 5, _u(A_H, A_T, B_H, B_T), false);
        bytes32 digest = anchor.stateDigest(s);
        bytes[] memory sigs = _signAll(anchor, s, pks);
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(bobPk, digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        sigs[1] = abi.encodePacked(r, bytes32(n - uint256(sv)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(LightsphereAnchor.BadSignatures.selector);
        anchor.checkpoint(s, sigs);
    }

    function test_rejectsBrokenConservation() public {
        T.SphereState memory s = _state(sid, 5, _u(A_H + 1, A_T, B_H, B_T), false);
        bytes[] memory sigs = _signAll(anchor, s, pks);
        vm.expectRevert(LightsphereAnchor.ConservationViolated.selector);
        anchor.checkpoint(s, sigs);
    }

    function test_stateCannotBeReplayedOnAnotherSphereOrAnchor() public {
        T.SphereParams memory p = _params();
        p.salt = bytes32(uint256(1));
        bytes32 other = anchor.open(p);
        T.SphereState memory s = _state(sid, 5, _u(A_H, A_T, B_H, B_T), false);
        bytes[] memory sigs = _signAll(anchor, s, pks);
        // Same signatures, other sphere id in the state: the digest no longer matches.
        T.SphereState memory moved = _state(other, 5, _u(A_H, A_T, B_H, B_T), false);
        vm.expectRevert(LightsphereAnchor.InvalidStatus.selector); // other sphere is still FUNDING
        anchor.checkpoint(moved, sigs);

        LightsphereAnchor anchor2 = new LightsphereAnchor(address(0xC1A9), MIN_CHALLENGE);
        assertTrue(anchor2.stateDigest(s) != anchor.stateDigest(s));
        vm.chainId(296);
        bytes32 testnetDigest = anchor.stateDigest(s);
        vm.chainId(31337);
        assertTrue(testnetDigest != anchor.stateDigest(s));
    }

    function test_ed25519ParticipantViaHAS() public {
        T.SphereState memory s = _state(sid, 7, _u(A_H - 1, A_T, B_H + 1, B_T), false);
        bytes32 digest = anchor.stateDigest(s);
        bytes[] memory sigs = _signAll(anchor, s, pks);
        // Pretend Bob's account has an ED25519 key: a 64-byte signature that 0x16a accepts.
        sigs[1] = abi.encodePacked(keccak256("ed-r"), keccak256("ed-s"));
        vm.expectRevert(LightsphereAnchor.BadSignatures.selector);
        anchor.checkpoint(s, sigs);
        has.approveEd25519(bob, digest, sigs[1]);
        anchor.checkpoint(s, sigs);
        (uint64 version,) = anchor.latestState(sid);
        assertEq(version, 7);
    }

    function test_longZeroAliasFallsBackToHAS() public {
        address longZero = address(uint160(0x1234));
        has.mapLongZero(longZero, carol);
        T.SphereParams memory p = _params();
        p.participants[1] = longZero;
        p.initialDeposits = _u(0, 0, 0, 0);
        bytes32 id = anchor.open(p);
        uint256[] memory keys = new uint256[](2);
        (keys[0], keys[1]) = (alicePk, carolPk);
        T.SphereState memory s = _state(id, 1, _u(0, 0, 0, 0), true);
        anchor.closeCooperative(s, _signAll(anchor, s, keys));
        assertEq(uint8(anchor.status(id)), uint8(ILightsphereAnchor.Status.SETTLED));
    }

    function test_rejectsHtsTokenWithCustomFees() public {
        address feeToken = address(new FeeOnTransferToken());
        hts.register(feeToken, true);
        T.SphereParams memory p = _params();
        p.assets[1] = feeToken;
        vm.expectRevert(abi.encodeWithSelector(LightsphereAnchor.AssetHasCustomFees.selector, feeToken));
        anchor.open(p);
    }

    function test_rejectsFeeOnTransferErc20() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        T.SphereParams memory p = _params();
        p.assets[1] = address(feeToken);
        bytes32 id = anchor.open(p);
        feeToken.mint(alice, A_T);
        vm.deal(alice, A_H);
        vm.startPrank(alice);
        feeToken.approve(address(anchor), A_T);
        vm.expectRevert(LightsphereAnchor.FeeOnTransfer.selector);
        anchor.fund{value: A_H}(id);
        vm.stopPrank();
    }

    function test_reclaimAfterFundingDeadline() public {
        T.SphereParams memory p = _params();
        p.salt = bytes32(uint256(2));
        bytes32 id = anchor.open(p);
        vm.deal(alice, A_H);
        token.mint(alice, A_T);
        vm.startPrank(alice);
        token.approve(address(anchor), A_T);
        anchor.fund{value: A_H}(id);
        vm.stopPrank();
        vm.expectRevert(LightsphereAnchor.TooEarly.selector);
        anchor.reclaimFunding(id);
        vm.warp(p.fundingDeadline + 1);
        anchor.reclaimFunding(id);
        assertEq(anchor.claimable(alice, HBAR), A_H);
        assertEq(anchor.claimable(bob, HBAR), 0);
    }

    function test_rejectsShortChallengePeriod() public {
        T.SphereParams memory p = _params();
        p.challengePeriod = MIN_CHALLENGE - 1;
        vm.expectRevert(LightsphereAnchor.InvalidParams.selector);
        anchor.open(p);
    }

    /// Any conserving split, at any version, settles exactly what was signed and empties the escrow.
    function testFuzz_settlementMatchesSignedState(uint64 version, uint256 hbarToBob, uint256 tokToAlice) public {
        version = uint64(bound(version, 1, type(uint64).max));
        hbarToBob = bound(hbarToBob, 0, A_H);
        tokToAlice = bound(tokToAlice, 0, B_T);
        T.SphereState memory s =
            _state(sid, version, _u(A_H - hbarToBob, A_T + tokToAlice, B_H + hbarToBob, B_T - tokToAlice), true);
        anchor.closeCooperative(s, _signAll(anchor, s, pks));
        assertEq(anchor.claimable(alice, HBAR) + anchor.claimable(bob, HBAR), A_H + B_H);
        assertEq(anchor.claimable(alice, address(token)), A_T + tokToAlice);
        assertEq(anchor.escrow(sid, HBAR), 0);
        assertEq(anchor.escrow(sid, address(token)), 0);
    }

    function test_gas_sixteenParticipantClose() public {
        uint256 n = 16;
        T.SphereParams memory p;
        p.mode = T.MODE_SIGNED;
        p.participants = new address[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            keys[i] = 0x1000 + i;
            p.participants[i] = vm.addr(keys[i]);
        }
        p.assets = new address[](1);
        p.initialDeposits = new uint256[](n);
        p.challengePeriod = MIN_CHALLENGE;
        p.fundingDeadline = uint64(block.timestamp + 1 days);
        bytes32 id = anchor.open(p);
        T.SphereState memory s = _state(id, 1, new uint256[](n), true);
        bytes[] memory sigs = _signAll(anchor, s, keys);
        uint256 g = gasleft();
        anchor.closeCooperative(s, sigs);
        emit log_named_uint("closeCooperative gas, 16 participants", g - gasleft());
    }
}
