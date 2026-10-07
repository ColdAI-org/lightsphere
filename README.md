# Lightsphere reference implementation

Reference implementation of the Lightsphere HIP
([hiero-improvement-proposals#1563](https://github.com/hiero-ledger/hiero-improvement-proposals/pull/1563)):
off-ledger execution spheres whose assets are escrowed on a Hiero network.

- **Signed mode.** 2 to 16 participants co-sign each state update (EIP-712). The anchor contract
  enforces the newest state that all participants signed.
- **Network mode.** The sphere is itself a Hiero network, connected to the anchor ledger over CLPR. It
  sends balance checkpoints, and users can exit from the last checkpoint if the sphere halts.

| Directory     | What it is                                                                                  |
|---------------|---------------------------------------------------------------------------------------------|
| `contracts/`  | `LightsphereAnchor`, `LightsphereGateway`, mocks for HTS (`0x167`), HAS (`0x16a`) and CLPR, and the Foundry tests |
| `harness/`    | Go: `lsvectors` (cross-language vectors), `lsbench` (throughput by the HIP's accounting rule), `lsverify` (re-check a report) |
| `ts/`         | TypeScript client (viem): state signing, sphere IDs, and a watchtower, with an end-to-end test on anvil |
| `reports/`    | `lsbench` reports                                                                           |

## Run it

```bash
cd contracts && forge test
```

```bash
cd harness && go run ./cmd/lsbench -duration 70s -keys ed25519 -out ../reports/my-machine.json
```

```bash
cd harness && go run ./cmd/lsverify ../reports/my-machine.json
```

```bash
cd ts && npm install && npm run abi && npm test
```

The TypeScript tests read the Foundry build output, so run `forge build` first. The end-to-end test starts
its own `anvil`.

## What the tests establish

- **Conservation after a halt.** `testFuzz_haltConservesFunds` runs random interleavings of 48 operations:
  deposits, failed CLPR deliveries in both directions, sphere transfers, withdrawals to any address,
  checkpoints, single-message relays in each direction, and releases. It then halts the sphere and has
  every account exit by the best available route. With an honest sphere, total payouts must equal total
  deposits exactly, and no exit may revert. This has passed 20,000 runs. It found two flaws in the first
  HIP draft, both now fixed in the spec:
  1. **Double payout.** A withdrawal funded by a transfer made after a checkpoint could be paid on top of
     the sender's checkpointed exit. The fix is that withdrawals are released only after a checkpoint
     covering them arrives.
  2. **Wrong account.** Withdrawals paid to a different address were counted against the recipient
     instead of the account that burned them.
- **Cross-language agreement.** The Go harness, the Solidity contract and viem all compute the same domain
  separator, sphere ID and digests from `contracts/test/vectors/signed-v1.json`. The Go and viem
  signatures are byte-identical (RFC 6979), and the contract settles a sphere using them.
- **Disputes.** A stale close is replaced inside the challenge window. Unit tests cover this in Solidity,
  and the watchtower does it end to end on anvil.

## Measured

| Item                                                        | Result                                            |
|-------------------------------------------------------------|---------------------------------------------------|
| Signed-mode throughput, Apple M1 Max (10 cores), 2-party ED25519 | about 46k effective tx/s sustained over 65 s (`reports/`) |
| Same machine, ECDSA (secp256k1)                             | about 45k effective tx/s                          |
| `closeCooperative`, 16 participants                         | about 214k gas                                    |
| Sphere-local transfer (two depth-20 leaf updates)           | about 114k gas                                    |

Throughput scales with the number of machines, because spheres are independent: 40M effective tx/s would
take roughly 870 machines like this one. The reports are offline runs. A public claim also needs the
anchor-ledger transaction IDs of every open and settlement, as the HIP requires.

## Not production-ready

These contracts have not been audited. Anchor-side HTS handling has been tested only against a mock of
`0x167`; it has not yet been run on Hedera testnet. The gateway keeps sphere balances in contract storage
for clarity, whereas a production sphere network could keep the tree in native state.

License: Apache-2.0
