# Concepts

Lightsphere moves the busy part of an application off the ledger and keeps the ledger as the judge. A small group
runs its interaction off-ledger, at whatever speed its machines allow, and the ledger is only involved at the
start (to lock the stakes) and at the end (to pay out what the group agreed). If the group falls out, the ledger
decides using rules every member signed up to in advance.

This page explains the idea and the vocabulary. The two modes have their own pages:
[signed mode](signed-mode.md) and [network mode](network-mode.md).

## Why

Many applications produce thousands of state changes between the same few parties, and almost none of those
changes need global ordering:

- **A game.** Two players make moves against each other; only the final result matters to anyone else.
- **Agent payments.** One AI agent pays another per request, many times a second.
- **Streaming payments.** A viewer pays a creator per second watched.
- **Order matching.** A matching engine settles net positions, not every quote.

Putting each of those changes on a ledger costs a fee and a round trip every time, and it competes for blockspace
with everyone else. Off-ledger channels that settle to a base ledger are the standard answer, and other ecosystems
have shipped them: Lightning on Bitcoin, state channels on Ethereum, and in 2026 Sui's "programmable tunnels".
Hiero had no standard, so every team that wanted channels wrote its own escrow, signature format and dispute
rules, and none of them worked with each other. Lightsphere is that standard, proposed as a Hiero Improvement
Proposal ([hiero-improvement-proposals#1563](https://github.com/hiero-ledger/hiero-improvement-proposals/pull/1563)).

Hiero networks are a good anchor for this:

- **Low, predictable fees.** Opening and closing a sphere is cheap compared with what it carries.
- **Fast finality with no reorgs.** A challenge that lands on time cannot be undone by a reorg.
- **Every account type can join.** Each participant names a plain secp256k1 signing key, so Hedera accounts with
  ECDSA, ED25519 or threshold keys all take part the same way, and rotating an account's keys never invalidates a
  signed state.
- **CLPR.** Hiero networks can already exchange state-proven messages over CLPR, so a private Hiero network can act
  as a sphere without a new bridge.

## Vocabulary

| Term | Meaning |
|---|---|
| **Sphere** | One instance of off-ledger execution, identified by a 32-byte `sphereId` |
| **Anchor ledger** | The Hiero network that holds the sphere's assets in escrow, for example Hedera mainnet |
| **Anchor contract** | `LightsphereAnchor`, the contract on the anchor ledger that escrows, judges disputes and pays out |
| **Participant** | In signed mode, one of the 2–16 accounts named when the sphere is opened. It funds, can start a close, and receives payouts |
| **Signing key** | In signed mode, the secp256k1 address each participant names to sign states. For an ECDSA account it is usually the account's own address |
| **State** | In signed mode, a snapshot of every participant's balances plus a hash of the application's own data, with a version number |
| **Fully signed** | A state carrying a valid signature from every participant, in participant order |
| **Challenge window** | In signed mode, the time after someone starts a close during which anyone can submit a newer fully signed state |
| **Watchtower** | A service that holds a participant's newest fully signed state and submits it if a stale close appears |
| **Sphere network** | In network mode, the Hiero network that runs the sphere |
| **Gateway** | `LightsphereGateway`, the contract on the sphere network that pairs with the anchor over CLPR |
| **Checkpoint** | In network mode, a Merkle root of every account's balance, sent from the sphere to the anchor at a fixed interval |
| **Halt** | In network mode, the state a sphere enters after the anchor has heard nothing from it for `haltTimeout`. Users then exit from the last checkpoint |
| **Effective transaction** | The unit of throughput: a new state version that every participant has signed and every other participant has verified |

## The two modes

| | Signed mode | Network mode |
|---|---|---|
| Who runs the sphere | The participants themselves | A Hiero network with its own validators |
| Members | 2–16, fixed when opened | Anyone with an account on the sphere network |
| How a state is agreed | Every participant signs it | The sphere network's consensus |
| Trust needed | None: no state can take your funds unless you signed it | The sphere network's validators (a supermajority could lie) |
| Liveness | One offline participant stops progress; the others close on-ledger | Continues while the sphere network runs |
| Throughput | Grows with machines: about 4,700 effective tx/s per core measured | The sphere network's own throughput |
| Settles via | One anchor transaction | CLPR messages: deposits, withdrawals, checkpoints |
| If things go wrong | Challenge window, watchtowers | Halt, then exit from the last checkpoint |
| Typical use | Games, agent payments, streaming | Private institutional networks (for example a HashSphere) settling to a public Hiero network |

Signed mode is a generalised state channel: no participant has to trust any other participant, or anyone else.
Network mode trades that property for open membership and continuous operation, and it states the trust
assumption plainly (see [security](security.md)).

## How it relates to other designs

- **Sui programmable tunnels.** The same off-ledger-then-settle idea. Sui's tunnels are two-party and settle only to
  Sui. Lightsphere adds a multi-party mode (network mode), a standard signature format, and through CLPR a path to
  settle across ledgers.
- **Lightning.** Two-party payment channels with a penalty rule: cheat and you lose everything. Lightsphere uses
  version numbers instead, which is simpler on an account-based ledger: the newest fully signed state wins.
- **Perun, Counterfactual, ForceMove.** Generalised state channels with on-chain judging of application rules.
  Lightsphere v1 carries application state as an opaque hash; on-chain adjudicators are an open issue in the HIP.
- **Rollups.** Rollups give open membership and global state, at the cost of a sequencer, data availability and
  proof systems. Spheres are much lighter but have fixed membership (signed mode) or a trusted validator set
  (network mode). They complement each other.

## What "TPS" means here

Off-ledger throughput is easy to inflate, so the HIP defines it precisely. An **effective transaction** is a state
with a new version that every participant has signed and every other participant has verified. Unsigned proposals
and partially signed states do not count. A conforming report gives both the peak rate and the rate sustained over
at least 60 seconds, the hardware, and the anchor-ledger transaction IDs of every open and settlement. See
[benchmarking](benchmarking.md).
