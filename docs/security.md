# Security

> [!WARNING]
> Lightsphere is pre-release. The contracts have not had an external audit and have run only on local networks,
> against a mock of the HTS system contract and a mock CLPR service. Do not use them with real value.

This page sets out what each mode protects against, the invariants the code is meant to keep and how each one is
tested, the known limitations, and the history of every issue found so far.

## Trust model

### Signed mode

**No participant trusts anyone.** The anchor only ever settles a state that every participant signed, or the
initial deposits. A participant's funds can move only by a state that participant signed.

The protection depends on availability. A participant who is offline for the whole challenge window, with no
watchtower, can lose to an older state that all participants once signed. Participants should choose a
challenge period that covers their worst expected downtime and use a watchtower for long-lived spheres.

### Network mode

**Members trust the sphere network's validators and the CLPR verifier for the Channel.**

- **If the sphere network stops:** members exit from the last checkpoint and the anchor pays out exactly what it
  holds.
- **If it lies:** a colluding supermajority of the sphere's validators, or a compromised verifier, could forge
  withdrawals or checkpoints.

Two limits contain the damage:

- **Per-sphere escrow cap.** The anchor never pays out more for a sphere than was deposited into it. A dishonest
  sphere can lose its own escrow and nothing else on the anchor.
- **Public configuration.** The sphere ID commits to the gateway, the Channel and the timing, so members can see
  whose validators they are trusting before depositing. Wallets must show this and should keep an allow-list.

## Invariants and how they are tested

| # | Invariant | Tested by |
|---|---|---|
| 1 | A signed-mode settlement pays exactly the balances of a state every participant signed, or the initial deposits | `testFuzz_settlementMatchesSignedState`, `test_staleCloseIsReplacedDuringWindow`, `test_closeWithNoStateReturnsDeposits` |
| 2 | No state can create funds: for each asset, balances sum to the deposits | `test_rejectsBrokenConservation`; `conserves()` in the client; `lsverify` |
| 3 | A signature is valid for exactly one sphere, one anchor, one chain and one signer | `test_stateCannotBeReplayedOnAnotherSphereOrAnchor`, `test_joinSignatureIsBoundToSphereAndParticipant`; the vector tests in Go, Solidity and TypeScript |
| 4 | Only low-`s`, 65-byte signatures with `v` in {0, 1, 27, 28} are accepted, by the anchor and by every client | `test_rejectsHighSAndBadV`; TypeScript `high-s and out-of-range v are rejected`; Go `TestCheck` |
| 5 | A participant's signed states stay valid whatever happens to their Hedera account keys | `test_accountWithSeparateSigningKey` (signatures depend only on the key bound into the sphere ID) |
| 6 | A unilateral close always ends: the window is between the deployment's minimum and 30 days | `test_rejectsChallengePeriodOutOfRange` |
| 7 | Network mode, honest sphere: total paid out equals total deposited, for any message interleaving and any halt time, and no exit reverts | `testFuzz_haltConservesFunds` (10,000 runs in CI; 20,000 locally) |
| 8 | Network mode: payouts never exceed deposits, even when CLPR drops Response callbacks | `testFuzz_haltConservesFunds` with dropped responses; `test_droppedSuccessCallbackCannotOverpay` |
| 9 | Network mode: a sphere can never be paid more than its own escrow | `_credit` checks every payout against the sphere's escrow; `testFuzz_haltConservesFunds` asserts the escrow ends at zero |
| 10 | A token fee added after `open` cannot take other spheres' escrow | `test_customFeeAddedAfterOpenBlocksTokenPayout` |
| 11 | The watchtower never keeps a state whose signatures do not verify, and keeps working through errors and restarts | `watchtower.e2e.test.ts` (forged states, restart with backfill) |

## Known limitations

- **Not audited, not yet on Hedera.** HTS behaviour is modelled by a mock. In particular, how Hedera charges a
  custom fee when a contract sends a token, and what sender address native Hiero CLPR reports to applications,
  must be confirmed on a real network before any use with value.
- **Lost refunds in network mode.** If CLPR loses the failure Response for a deposit, the anchor never learns that
  the deposit failed.
  - While the sphere runs, the funds stay in escrow, unrefunded.
  - After a halt, they return through the recipient's exit if the recipient has a leaf in the last checkpoint.
    Otherwise they stay in escrow. They are never paid twice, but the depositor cannot recover them.
  - A timeout-based reclaim is an open issue.

  The same applies on the sphere side: a lost failure Response for a WITHDRAW leaves the burned balance unrefunded
  on the sphere until a halt, when the exit formula returns it.
- **Data availability.** An exit with a proof needs the account's leaf and proof for the last accepted checkpoint.
  Wallets should keep their proof after every checkpoint, and operators should publish every checkpoint's tree
  somewhere that does not depend on the sphere network.
- **Token controls.** An HTS token's freeze, KYC, pause, wipe and delete keys still apply to the anchor's balance.
  - A paused token delays payouts.
  - A wiped or deleted token loses the escrow in that token.
  - A custom fee added after `open` pauses payouts in that token until it is removed.

  Participants accept the controls of the tokens they deposit.
- **Confidentiality.** Signed-mode states are private to the participants until settlement, which reveals only the
  final balances. In network mode, CLPR payloads are not encrypted: deposits, withdrawals and each checkpoint's
  balances are visible on both ledgers.
- **Equivocation.** If participants sign two different states with the same version, the anchor accepts whichever
  arrives first. Clients must never sign a version twice.

## History

### External review before release (October 2026)

An independent adversarial review of the contracts, the Go harness and the TypeScript client found 14 issues: three
high, six medium and five low. Eight were confirmed by a proof-of-concept run, and five by reading the Hedera
services source. All are fixed, and each fix has a regression test.

| Severity | Finding | Fix |
|---|---|---|
| High | Signatures were checked with HIP-632 `isAuthorizedRaw`, which checks an ED25519 account's *current* key. Rotating the key made every state a participant had signed unusable. | Signed mode uses a secp256k1 signing key per participant, bound into the sphere ID and checked with `ecrecover`. |
| High | Each ED25519 check through `isAuthorizedRaw` costs about 1.5M gas, so a sphere with about ten ED25519 participants could never record a state. | Same fix: every check is an `ecrecover`. A 16-party close costs about 213,000 gas. |
| High, unconfirmed on Hedera | A custom fee added to an HTS token after `open` would be charged to the anchor on payout, out of every sphere's escrow. | Fees are re-checked before every token payout, and payouts in that token pause while a fee exists. Token and HBAR balance deltas are also checked. |
| Medium-high | `isAuthorizedRaw` rejects ECDSA signatures for long-zero accounts, so such a participant could never sign, yet the mock accepted them. | No dependence on `isAuthorizedRaw`. Each participant's signing key proves itself with a join signature at funding. |
| Medium | The proof-free exit relied on CLPR success callbacks, which are best-effort. A dropped callback let an account that had spent its deposit exit again, and blocked an honest exit. | The rule depends only on deposits sent and refunds received. |
| Medium | Zero-amount sphere transfers and dust deposits created tree leaves, enough to fill the depth-20 tree. | Zero amounts and `address(0)` are rejected; the tree is 32 levels deep (about 4.3 billion leaves). |
| Medium | The watchtower stored unverified states, so it could be poisoned. Errors in its event handler escaped, and it forgot everything on restart. | It verifies signatures before storing anything, catches and reports errors, persists to a store, replays from a block, and sweeps on a timer. |
| Medium | The TypeScript verifier accepted high-`s` signatures that the anchor rejects. | It applies the anchor's exact rules. |
| Low | `lsverify` passed samples with no signatures and could not tie signers to a sphere. | Reports carry each sphere's parameters; `lsverify` recomputes the sphere ID and applies the anchor's rules. |
| Low | A sphere transfer to `address(0)` stranded funds. | Rejected. |
| Low | An unbounded challenge period let one participant block unilateral closes. | Capped at 30 days. |
| Low | Lost failure Responses leave deposits or withdrawals unrefunded while the sphere runs. | Documented above; a reclaim is an open issue. |
| Low | The `ecrecover` fast path accepted more than `isAuthorizedRaw` did, contradicting the HIP. | Moot: `ecrecover` is now the only rule, and the HIP says so. |
| Info | The text of the HIP and the code disagreed in a few places: reentrancy guard scope, `closeCooperative` while CLOSING, stale states in `startClose`, and token deletion. `lsbench` computed rates from tick counts, and its sampling favoured the start of the run. HBAR owed to a contract that cannot receive it was stuck. | The HIP and the code now agree. `lsbench` uses wall-clock rates and uniform sampling. `withdrawTo` added. |

### Found while building the reference implementation (October 2026)

Both of these were flaws in the first draft of the HIP itself, and both are fixed in the specification.

- **Double payout after a halt.** A withdrawal funded by a transfer made after the last checkpoint could be paid
  on top of the sender's checkpointed exit. Fix: withdrawals are released only after a checkpoint covering their
  epoch arrives. Regression test: `test_postCheckpointTransferCannotBePaidTwice`.
- **Withdrawals counted against the wrong account.** A withdrawal paid to another address was counted against the
  recipient, so the account that burned it got it back in its exit. Fix: WITHDRAW names the burning account. The
  conservation fuzz test found this one. Regression test: `test_withdrawalToAnotherAddressIsCountedAgainstSender`.

## Reporting

See [SECURITY.md](../SECURITY.md). Please report privately through GitHub's private vulnerability reporting.
