# Integration guide

This guide is for wallet, application and service developers. It covers the TypeScript client, running a
watchtower, the Go package, and what is different about deploying on Hedera.

## TypeScript client

The client in [`ts/`](../ts) is built on [viem](https://viem.sh). It needs Node 23.6 or later, which runs
TypeScript directly.

```bash
cd ts && npm install && npm run abi
```

`npm run abi` regenerates `src/anchorAbi.ts` from the Foundry build, so run `forge build` in `contracts/` first.

### Compute a sphere ID

```ts
import { sphereId, HBAR } from "./src/index.ts";

const params = {
  mode: 0,                                   // signed mode
  participants: [alice.address, bob.address], // the accounts that fund and get paid
  signers: [alice.address, bob.address],     // their secp256k1 signing addresses (here, the same keys)
  assets: [HBAR],
  initialDeposits: [10n * 10n ** 8n, 10n * 10n ** 8n], // 10 HBAR each, in tinybars (see "HBAR units" below)
  challengePeriod: 3600n,
  fundingDeadline: BigInt(Math.floor(Date.now() / 1000) + 86_400),
  networkConfig: "0x",
  salt: keccak256(toHex("my-game-42")),
} as const;

const id = sphereId(296, anchorAddress, params); // the same value open() returns
```

### Fund

Each participant's signing key signs `JoinSphere(sphereId, participant)`, which proves the key works before any
money depends on it:

```ts
import { signJoin } from "./src/index.ts";

const joinSig = await signJoin(aliceSigningKey, 296, anchorAddress, id, alice.address);
await walletClient.writeContract({
  address: anchorAddress,
  abi: anchorAbi,
  functionName: "fund",
  args: [id, joinSig],
  value: 10n * 10n ** 18n, // 10 HBAR: the relay takes weibars (see "HBAR units" below)
});
```

### Sign, verify and settle a state

```ts
import { signState, verifyStateSignatures, conserves, stateDigest } from "./src/index.ts";

const state = {
  sphereId: id,
  version: 1_000n,
  balances: [8n * 10n ** 8n, 12n * 10n ** 8n], // Alice paid Bob 2 HBAR
  appDataHash: keccak256(toHex(JSON.stringify(gameState))),
  isFinal: true,
};

// Before signing anything, check that it conserves funds and moves the version forward.
if (!conserves(state, [...params.initialDeposits], params.assets.length)) throw new Error("bad state");

const sigAlice = await signState(alice, 296, anchorAddress, state);
const sigBob = await signState(bob, 296, anchorAddress, state);
// Exactly the anchor's rules: one signature per signer, in order, 65 bytes, low s, v in {0, 1, 27, 28}.
await verifyStateSignatures(296, anchorAddress, state, params.signers, [sigAlice, sigBob]); // true

await walletClient.writeContract({
  address: anchorAddress,
  abi: anchorAbi,
  functionName: "closeCooperative",
  args: [state, [sigAlice, sigBob]],
});
```

`stateDigest(chainId, anchor, state)` returns the EIP-712 digest. `isValidSignature(hash, signature, signer)`
checks a single signature by the same rules.

### Rules for a wallet

- **Never sign two different states with the same version.** The anchor accepts whichever reaches it first.
- **Verify every counterparty signature** with `verifyStateSignatures` before treating a state as yours. A
  signature that recovers to the right address but has a high `s` is rejected by the anchor, so the client rejects
  it too.
- **Check conservation and the version** before signing.
- **Keep every fully signed state** until a newer one is fully signed, and hand it to a watchtower.
- **Show the user the sphere's parameters** (participants, assets, deposits, challenge period, and in network mode
  the gateway and Channel) before they fund it.

## Run a watchtower

```ts
import { Watchtower, FileStore } from "./src/index.ts";

const tower = new Watchtower({
  publicClient,
  walletClient,
  anchor: anchorAddress,
  store: new FileStore("./watchtower.json"), // survives restarts; MemoryStore is the default
});

// The participant's wallet calls this after every fully signed update. It returns false, and keeps nothing, unless
// the state is newer than the one held and every signature matches the signing addresses on the anchor.
await tower.guard({ state, signatures: [sigAlice, sigBob] });

// Watch for CloseStarted, replaying from the last block seen before a restart, and re-check every guarded
// sphere once a minute in case an event was missed.
await tower.start({
  fromBlock: lastSeenBlock,
  sweepInterval: 60_000,
  onSubmit: (sphereId, tx) => console.log(`replaced a stale close on ${sphereId}: ${tx}`),
  onError: (e) => console.error(e), // errors never stop the tower
});
```

The watchtower only ever calls `checkpoint`, which anyone may call with a fully signed state. It needs no keys from
the participants and holds no funds, only a funded account to pay for its own transactions. It simulates each
submission first, so a race (someone else submitted the same state, or the window just closed) is skipped quietly
instead of failing.

`test/watchtower.e2e.test.ts` runs on a local anvil chain:

- **The dispute.** Alice starts a close with version 3, the watchtower replaces it with version 250, and after the
  window Bob is paid by version 250.
- **Forged states.** A forged state with a version of 2^60 is refused.
- **Restart.** A tower that was offline when the close started catches it after a restart from its file store.

## Go

```go
import "github.com/ColdAI-org/lightsphere/harness/state"

dom := state.NewDomain(296, anchor)                       // chain id, anchor address
id, _ := dom.SphereID(&params)
join, _ := state.SignECDSA(key, dom.JoinDigest(id, participant)) // for fund()
sig, _ := state.SignECDSA(key, dom.Digest(&sphereState))   // 65 bytes, low s, v in {27, 28}
```

The Go package, the Solidity contract and viem produce identical digests and byte-identical signatures (state
and join) for the committed vectors (`contracts/test/vectors/signed-v1.json`); each test suite checks this.

## Deploying on Hedera

The contracts target the Cancun EVM and use only what Hedera's EVM supports. Things to get right:

### HBAR units

Inside the EVM, `msg.value` and balances are in **tinybars** (1 HBAR = 10^8 tinybars). Write HBAR amounts in
`initialDeposits`, states and `depositToSphere` in tinybars. The Hedera JSON-RPC relay, however, takes a
transaction's `value` in **weibars** (tinybars × 10^10) and converts it. So to fund 10 HBAR, the state says
`1_000_000_000` and the transaction sends `value: 10n * 10n ** 18n`.

### HTS tokens

- **Association.** An account must be associated with an HTS token before it can hold it. `open` associates the
  anchor with every HTS asset through the HTS system contract (`0x167`). Recipients must be associated (or have
  automatic association slots) before they `withdraw`.
- **Allowances.** Funding pulls tokens with the ERC-20 `transferFrom` that HTS tokens expose ([HIP-218](https://hips.hedera.com/hip/hip-218),
  [HIP-376](https://hips.hedera.com/hip/hip-376)), so each participant approves the anchor first.
- **Custom fees.** Tokens with custom fees are rejected at `open`. Because a fee schedule can change later, the
  anchor checks again before every token payout and pauses payouts in that token while a fee exists.
- **Token controls stay in force.** A token's freeze, KYC, pause and wipe keys still apply to the anchor's balance.
  A paused token delays withdrawals; participants accept the controls of the tokens they deposit.

### Accounts and signing keys

- **Every participant names a secp256k1 signing address,** and the anchor checks state signatures with `ecrecover`
  against it.
- **An ECDSA account** usually uses its own EVM address as the signing address.
- **Other accounts** (ED25519, threshold or key-list keys, or an account named by its long-zero address) name a
  separate secp256k1 key they control, for example a session key in the wallet. The account itself is still the
  participant: it funds, starts closes and receives payouts.
- **Rotating keys is safe.** Rotating the account's Hedera keys later does not affect states already signed.

### Chain IDs

| Network | Chain ID |
|---|---|
| Hedera mainnet | 295 |
| Hedera testnet | 296 |
| Hedera previewnet | 297 |

### Network mode

Network mode also needs a CLPR Service on both ledgers and an open Channel between them, with a Connector funded
for the anchor's outbound DEPOSIT messages and one on the sphere side for WITHDRAW and CHECKPOINT. Deploy the
gateway with the anchor's address, open the sphere on the anchor with the gateway's address in `networkConfig`,
then call `initialize(sphereId)` on the gateway once. Schedule `checkpoint()` on the gateway at
`checkpointInterval`; anyone may call it.

> [!IMPORTANT]
> The reference contracts have been tested against mocks of the HTS and Hedera Account Service system contracts,
> not yet on Hedera testnet. See [security](security.md) for the audit status.
