# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-07

First public release of the reference implementation of the Lightsphere HIP
([hiero-improvement-proposals#1563](https://github.com/hiero-ledger/hiero-improvement-proposals/pull/1563)).

### Added

- `LightsphereAnchor`:
  - Signed mode: 2–16 participants, each with a secp256k1 signing key bound into the sphere ID and proven with a
    join signature at funding. EIP-712 states, a bounded challenge window, pull payments, `withdrawTo`, HTS
    association, and custom-fee checks at open and at every payout.
  - Network mode: CLPR deposits, checkpoint-gated withdrawals, halt, exits with and without a Merkle proof, and a
    per-sphere escrow cap.
- `LightsphereGateway`: the sphere-side CLPR application, with an incremental depth-32 Merkle tree and
  `LeafUpdated` events for rebuilding proofs.
- Foundry suite with a mock of HTS (`0x167`) and an order-preserving two-sided CLPR service that can fail
  deliveries and drop responses. It includes the `testFuzz_haltConservesFunds` conservation fuzz test.
- Go harness: the state encoding, `lsbench`, `lsverify`, `lsvectors`, and cross-language vectors.
- TypeScript client on viem: sphere IDs, state and join signing, strict verification, and a watchtower that
  validates states before guarding them, persists them, replays missed events and sweeps on a timer. Tested end to
  end on anvil.
- Documentation, brand, CI (Foundry, Go, TypeScript, deep fuzz, CodeQL) and a first benchmark report.

### Fixed before release (external review)

- Signatures were checked through HIP-632 `isAuthorizedRaw`. Per the Hedera services source, that made an
  ED25519 participant able to invalidate every state they had signed by rotating their key. It also cost about
  1.5M gas per ED25519 check, and it rejected long-zero ECDSA accounts. Signed mode now uses per-participant
  secp256k1 signing keys checked with `ecrecover`, plus a join signature at funding.
- A custom fee added to an HTS token after `open` could have been paid out of other spheres' escrow. Fees are now
  re-checked before every token payout, alongside balance-delta checks.
- The proof-free exit relied on CLPR success callbacks, which are best-effort. A dropped callback could overpay an
  account and block an honest one. The rule now depends only on deposits sent and refunds received.
- Gateway: zero-amount transfers created leaves for free, and transfers or withdrawals to `address(0)` stranded
  funds. Both are now rejected, and the tree is now 32 levels deep.
- The challenge period is now capped at 30 days, so one participant can no longer block a unilateral close.
- Watchtower:
  - It stored states without checking their signatures, so it could be poisoned; it now checks them.
  - Errors in its event handler could crash it; they are now caught and reported.
  - It now persists what it guards, replays events from a given block, and sweeps on a timer.
- The TypeScript verifier accepted high-`s` signatures that the anchor rejects.
- `lsverify` passed samples with no signatures; it now applies the anchor's rules and recomputes the sphere ID.
- `lsbench` computed rates from tick counts rather than wall-clock time, and its sampling favoured the start of
  the run.

### Fixed in the specification, before release (found while building the reference implementation)

- Network mode could pay the same funds twice after a halt: a withdrawal funded by a transfer made after the last
  checkpoint was paid on top of the sender's checkpointed exit. Withdrawals are now released only after a
  checkpoint covering their epoch arrives.
- Withdrawals paid to another address were counted against the recipient instead of the account that burned them,
  so that account's exit added them back. WITHDRAW now names the burning account.

[Unreleased]: https://github.com/ColdAI-org/lightsphere/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ColdAI-org/lightsphere/releases/tag/v0.1.0
