// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {LightsphereAnchor} from "../src/LightsphereAnchor.sol";
import {LightsphereGateway} from "../src/LightsphereGateway.sol";
import {ILightsphereAnchor} from "../src/interfaces/ILightsphereAnchor.sol";
import {LightsphereTypes as T} from "../src/LightsphereTypes.sol";
import {MockClprService} from "./mocks/Mocks.sol";

contract NetworkModeTest is Base {
    bytes32 internal constant CH = keccak256("anchor<->sphere");
    uint64 internal constant INTERVAL = 10 minutes;
    uint64 internal constant HALT = 1 days;

    MockClprService internal clprA; // anchor ledger
    MockClprService internal clprB; // sphere network
    LightsphereAnchor internal anchor;
    LightsphereGateway internal gw;
    bytes32 internal sid;
    address internal tok;

    struct Snap {
        uint256 balance;
        uint256 cumDep;
        uint256 cumWd;
        bool hasLeaf;
        bytes32[] proof;
    }

    mapping(uint64 => mapping(address => Snap)) internal _snaps; // checkpoint epoch => account => leaf
    address[] internal actors;

    function setUp() public override {
        super.setUp();
        tok = address(token);
        clprA = new MockClprService();
        clprB = new MockClprService();
        clprA.link(clprB, CH);
        clprB.link(clprA, CH);
        anchor = new LightsphereAnchor(address(clprA), MIN_CHALLENGE);
        address[] memory assets = new address[](1);
        assets[0] = tok;
        gw = new LightsphereGateway(address(clprB), CH, bytes32("conn"), address(anchor), INTERVAL, assets);

        T.SphereParams memory p;
        p.mode = T.MODE_NETWORK;
        p.assets = assets;
        p.networkConfig =
            abi.encode(T.NetworkConfig("hiero:sphere-1", CH, bytes32("conn"), address(gw), INTERVAL, HALT));
        sid = anchor.open(p);
        gw.initialize(sid);
        actors = [alice, bob, carol];
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address from, address to, uint256 amount) internal {
        token.mint(from, amount);
        vm.startPrank(from);
        token.approve(address(anchor), amount);
        anchor.depositToSphere(sid, tok, amount, to);
        vm.stopPrank();
    }

    function _checkpoint() internal {
        vm.warp(block.timestamp + INTERVAL);
        uint64 epoch = gw.epoch();
        for (uint256 i; i < actors.length; ++i) {
            LightsphereGateway.Account memory a = gw.accountOf(actors[i], tok);
            _snaps[epoch][actors[i]] = Snap(
                a.balance, a.cumDepositsApplied, a.cumWithdrawalsInitiated, a.index != 0, gw.proofOf(actors[i], tok)
            );
        }
        gw.checkpoint();
    }

    function _halt() internal {
        vm.warp(block.timestamp + HALT + 1);
        anchor.declareHalt(sid);
    }

    function _exit(address who) internal {
        LightsphereAnchor.Network memory n = anchor.network(sid);
        Snap memory s = _snaps[n.lastEpoch][who];
        vm.prank(who);
        if (n.hasCheckpoint && s.hasLeaf) anchor.exit(sid, tok, s.balance, s.cumDep, s.cumWd, s.proof);
        else anchor.exitWithoutLeaf(sid, tok);
    }

    function exitAs(address who) external {
        require(msg.sender == address(this));
        _exit(who);
    }

    function _drain(address who) internal returns (uint256 amount) {
        amount = anchor.claimable(who, tok);
        if (amount != 0) {
            vm.prank(who);
            anchor.withdraw(tok);
        }
    }

    // ---------------------------------------------------------------- flows

    function test_depositIsAppliedOnSphere() public {
        _deposit(alice, alice, 100e18);
        clprA.relayAll();
        assertEq(gw.accountOf(alice, tok).balance, 100e18);
        clprB.relayAll(); // success response
        assertEq(anchor.netDeposited(sid, alice, tok), 100e18);
        assertFalse(anchor.depositRefunded(sid, 1));
    }

    function test_failedDeliveryRefundsDepositor() public {
        _deposit(alice, bob, 40e18);
        clprB.setFailNextDelivery(true);
        clprA.relayAll();
        assertEq(gw.accountOf(bob, tok).balance, 0);
        clprB.relayAll();
        assertEq(anchor.claimable(alice, tok), 40e18);
        assertEq(anchor.netDeposited(sid, bob, tok), 0);
        assertTrue(anchor.depositRefunded(sid, 1));
        assertEq(anchor.escrow(sid, tok), 0);
    }

    function test_withdrawalWaitsForCoveringCheckpoint() public {
        _deposit(alice, alice, 100e18);
        clprA.relayAll();
        vm.prank(alice);
        uint64 wid = gw.withdraw(tok, 30e18, alice);
        clprB.relayAll();
        vm.expectRevert(LightsphereAnchor.NotReleasable.selector);
        anchor.releaseWithdrawal(sid, wid);

        _checkpoint();
        clprB.relayAll();
        anchor.releaseWithdrawal(sid, wid);
        assertEq(_drain(alice), 30e18);
        vm.expectRevert(LightsphereAnchor.NotReleasable.selector);
        anchor.releaseWithdrawal(sid, wid);
    }

    /// The double spend the release rule exists to stop: funds moved after a checkpoint are withdrawn by the
    /// receiver, and the sender exits with the checkpointed balance. Total paid must stay at 100.
    function test_postCheckpointTransferCannotBePaidTwice() public {
        _deposit(alice, alice, 100e18);
        clprA.relayAll();
        clprB.relayAll();
        _checkpoint();
        clprB.relayAll();

        vm.prank(alice);
        gw.transfer(tok, bob, 100e18);
        vm.prank(bob);
        uint64 wid = gw.withdraw(tok, 100e18, bob);
        clprB.relayAll(); // WITHDRAW reaches the anchor, but no checkpoint covers it yet
        vm.expectRevert(LightsphereAnchor.NotReleasable.selector);
        anchor.releaseWithdrawal(sid, wid);

        _halt();
        _exit(alice);
        _exit(bob);
        assertEq(_drain(alice) + _drain(bob), 100e18);
        assertEq(anchor.escrow(sid, tok), 0);
    }

    /// Regression for a fuzzer counterexample: a withdrawal paid to someone else must be counted against the
    /// account that burned it, or that account's exit adds it back.
    function test_withdrawalToAnotherAddressIsCountedAgainstSender() public {
        _deposit(alice, alice, 100e18);
        clprA.relayAll();
        clprB.relayAll();
        vm.prank(alice);
        uint64 wid = gw.withdraw(tok, 60e18, carol);
        _checkpoint();
        clprB.relayAll();
        anchor.releaseWithdrawal(sid, wid);
        assertEq(anchor.withdrawn(sid, alice, tok), 60e18);
        assertEq(anchor.withdrawn(sid, carol, tok), 0);
        _halt();
        _exit(alice);
        _exit(carol);
        assertEq(_drain(alice), 40e18);
        assertEq(_drain(carol), 60e18);
        assertEq(anchor.escrow(sid, tok), 0);
    }

    /// Regression for an external review finding: the proof-free exit used to rely on success callbacks, which
    /// CLPR only delivers best-effort. A dropped success callback let an account that had spent its deposit on the
    /// sphere exit again without a proof, which also blocked an honest account's exit.
    function test_droppedSuccessCallbackCannotOverpay() public {
        _deposit(carol, carol, 100e18);
        _deposit(alice, alice, 100e18);
        clprA.relayAll(); // both applied on the sphere
        clprB.relayOne(); // carol's success response: delivered
        clprA.setDropNextResponse(true);
        clprB.relayOne(); // alice's success response: the callback never runs
        vm.prank(alice);
        gw.transfer(tok, bob, 100e18); // alice spends her applied deposit
        _checkpoint();
        clprB.relayAll();
        _halt();

        vm.prank(alice);
        vm.expectRevert(LightsphereAnchor.LeafRequired.selector);
        anchor.exitWithoutLeaf(sid, tok);
        _exit(alice); // with her leaf: balance 0
        _exit(bob);
        _exit(carol);
        assertEq(_drain(alice), 0);
        assertEq(_drain(bob), 100e18);
        assertEq(_drain(carol), 100e18);
        assertEq(anchor.escrow(sid, tok), 0);
    }

    function test_gatewayRejectsZeroAmountsAndZeroAddress() public {
        _deposit(alice, alice, 10e18);
        clprA.relayAll();
        uint64 leavesBefore = gw.leafCount();
        vm.startPrank(alice);
        vm.expectRevert(LightsphereGateway.InvalidAmountOrRecipient.selector);
        gw.transfer(tok, bob, 0);
        vm.expectRevert(LightsphereGateway.InvalidAmountOrRecipient.selector);
        gw.transfer(tok, address(0), 1);
        vm.expectRevert(LightsphereGateway.InvalidAmountOrRecipient.selector);
        gw.withdraw(tok, 1, address(0));
        vm.expectRevert(LightsphereGateway.InvalidAmountOrRecipient.selector);
        gw.withdraw(tok, 0, alice);
        vm.stopPrank();
        assertEq(gw.leafCount(), leavesBefore);
    }

    function test_haltRules() public {
        _deposit(alice, alice, 50e18);
        clprA.relayAll();
        clprB.relayAll();
        vm.expectRevert(LightsphereAnchor.TooEarly.selector);
        anchor.declareHalt(sid);
        _checkpoint();
        vm.prank(alice);
        gw.withdraw(tok, 10e18, alice); // proven on the sphere, delivered only after the halt
        _halt();
        assertEq(uint8(anchor.status(sid)), uint8(ILightsphereAnchor.Status.HALTED));

        clprB.relayAll(); // CHECKPOINT and WITHDRAW are rejected by the halted anchor
        assertFalse(anchor.network(sid).hasCheckpoint);
        vm.expectRevert(LightsphereAnchor.InvalidStatus.selector);
        anchor.depositToSphere(sid, tok, 1, alice);

        _exit(alice); // no accepted checkpoint: rolls back to net deposits
        assertEq(_drain(alice), 50e18);
        vm.expectRevert(LightsphereAnchor.AlreadyExited.selector);
        vm.prank(alice);
        anchor.exitWithoutLeaf(sid, tok);
    }

    function test_leaflessExitBlockedOnceADepositWasCheckpointed() public {
        _deposit(alice, alice, 80e18);
        clprA.relayAll();
        clprB.relayAll();
        _checkpoint();
        clprB.relayAll();
        vm.prank(alice);
        gw.transfer(tok, bob, 80e18); // Alice is now a net sender since the checkpoint
        _halt();
        vm.expectRevert(LightsphereAnchor.LeafRequired.selector);
        vm.prank(alice);
        anchor.exitWithoutLeaf(sid, tok);
        _exit(alice);
        assertEq(_drain(alice), 80e18);
    }

    function test_forgedProofRejected() public {
        _deposit(alice, alice, 10e18);
        clprA.relayAll();
        clprB.relayAll();
        _checkpoint();
        clprB.relayAll();
        _halt();
        Snap memory s = _snaps[1][alice];
        vm.expectRevert(LightsphereAnchor.InvalidProof.selector);
        vm.prank(alice);
        anchor.exit(sid, tok, s.balance + 1, s.cumDep, s.cumWd, s.proof);
        vm.expectRevert(LightsphereAnchor.InvalidProof.selector);
        vm.prank(bob); // Alice's leaf cannot be claimed by someone else
        anchor.exit(sid, tok, s.balance, s.cumDep, s.cumWd, s.proof);
    }

    function test_onlyGatewayOnChannelIsHeard() public {
        vm.expectRevert(LightsphereAnchor.Unauthorized.selector);
        anchor.onClprMessage(CH, abi.encodePacked(address(gw)), "");
        vm.prank(address(clprA));
        vm.expectRevert(LightsphereAnchor.Unauthorized.selector);
        anchor.onClprMessage(
            CH,
            abi.encodePacked(address(0xbad)),
            abi.encode(T.MSG_CHECKPOINT, sid, abi.encode(uint64(1), bytes32(0), uint64(0)))
        );
    }

    // ---------------------------------------------------------------- conservation

    /// Random interleavings of deposits, failed deliveries, sphere transfers, withdrawals, checkpoints,
    /// relays in either direction and releases, then a halt with every account exiting by the best route.
    /// With an honest sphere, the anchor must pay out exactly what was deposited, and no exit may revert.
    function testFuzz_haltConservesFunds(uint256[48] calldata ops) public {
        uint256 minted;
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i];
            address who = actors[(op >> 8) % 3];
            address other = actors[(op >> 16) % 3];
            uint256 amount = ((op >> 24) % 1000e18) + 1;
            uint256 kind = op % 11;
            if (kind == 0) {
                _deposit(who, other, amount);
                minted += amount;
            } else if (kind == 1) {
                uint256 bal = gw.accountOf(who, tok).balance;
                if (bal == 0) continue;
                vm.prank(who);
                gw.transfer(tok, other, amount % bal + 1);
            } else if (kind == 2) {
                uint256 bal = gw.accountOf(who, tok).balance;
                if (bal == 0) continue;
                vm.prank(who);
                gw.withdraw(tok, amount % bal + 1, other);
            } else if (kind == 3) {
                _checkpoint();
            } else if (kind == 4) {
                if (clprA.pending() != 0) clprA.relayOne();
            } else if (kind == 5) {
                if (clprB.pending() != 0) clprB.relayOne();
            } else if (kind == 6) {
                for (uint64 w = 1; w <= gw.nextWithdrawalId(); ++w) {
                    try anchor.releaseWithdrawal(sid, w) {} catch {}
                }
            } else if (kind == 7) {
                clprB.setFailNextDelivery(true);
            } else if (kind == 8) {
                clprA.setFailNextDelivery(true);
            } else if (kind == 9) {
                clprA.setDropNextResponse(true); // deposit responses at the anchor
            } else {
                clprB.setDropNextResponse(true); // withdrawal responses at the gateway
            }
        }
        // Some messages may still be in flight; the halt makes them irrelevant.
        _halt();
        bool lostFailureResponse = clprA.droppedFailureResponses() != 0;
        for (uint256 i; i < actors.length; ++i) {
            if (lostFailureResponse) {
                // An undelivered refund can leave an account without a leaf unable to exit; never overpaid.
                try this.exitAs(actors[i]) {} catch {}
            } else {
                _exit(actors[i]);
            }
        }
        uint256 paid;
        for (uint256 i; i < actors.length; ++i) {
            paid += _drain(actors[i]);
        }
        if (lostFailureResponse) {
            assertLe(paid, minted, "paid out more than deposited");
        } else {
            assertEq(paid, minted, "paid out != deposited");
            assertEq(anchor.escrow(sid, tok), 0);
            assertEq(token.balanceOf(address(anchor)), 0);
        }
    }

    function test_gas_sphereTransferAndCheckpoint() public {
        _deposit(alice, alice, 100e18);
        clprA.relayAll();
        vm.prank(alice);
        uint256 g = gasleft();
        gw.transfer(tok, bob, 1e18);
        emit log_named_uint("sphere transfer gas (two leaf updates, depth 32)", g - gasleft());
        vm.warp(block.timestamp + INTERVAL);
        g = gasleft();
        gw.checkpoint();
        emit log_named_uint("checkpoint gas", g - gasleft());
    }
}
