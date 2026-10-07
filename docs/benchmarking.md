# Benchmarking

Off-ledger throughput is easy to inflate, so the Lightsphere HIP defines what to count, and this repository ships a
harness that counts exactly that and a verifier that lets anyone check the result.

## What counts

An **effective transaction** is a `SphereState` with a new version that:

1. every participant has signed, and
2. every other participant has verified.

Unsigned proposals, partially signed states, and states replaced before everyone verified them do not count. A
conforming report gives:

- the **peak** one-second rate and the **sustained** rate averaged over at least 60 seconds,
- the number of spheres and participants, and the hardware,
- the anchor-ledger transaction IDs of every `open` and settlement (for a public claim),
- a random sample of fully signed states, so third parties can check the signatures.

## Run it

```bash
cd harness
go run ./cmd/lsbench -duration 70s -out ../reports/my-machine.json
```

```bash
go run ./cmd/lsverify ../reports/my-machine.json
```

| Flag | Default | Meaning |
|---|---|---|
| `-spheres` | 1024 | Concurrent spheres |
| `-parties` | 2 | Participants per sphere (2–16) |
| `-workers` | number of CPUs | Worker goroutines; each owns a slice of the spheres |
| `-duration` | 70s | Measured time. 60 s or more after warm-up is needed for a conforming report |
| `-warmup` | 5 | Seconds left out of the sustained average |
| `-chain`, `-anchor` | 296, a fixed test address | The EIP-712 domain the states are signed for |
| `-samples` | 32 | Fully signed states included in the report |

**How the harness counts.**

- **Per update.** Each worker loops over its spheres. For every update it moves one unit between two random
  participants, bumps the version, computes the EIP-712 digest, and has **every** participant sign it with the
  secp256k1 signing key the anchor checks. Then **every** participant verifies **every other** participant's
  signature. Only then does it count one effective transaction. Any verification failure aborts the run.
- **Rates.** Rates are measured against the wall clock. Each one-second sample divides the transactions completed
  since the previous sample by the real time elapsed. The sustained rate is everything completed between the end
  of the warm-up and the end of the run, divided by that interval. Transactions completed after the last sample
  are not counted.
- **Samples.** Samples are drawn uniformly from the whole run (reservoir sampling, merged across workers in
  proportion to their output). Each sample carries its sphere's parameters, so a verifier can recompute the sphere
  ID.

**How `lsverify` checks a sample,** by the same rules as the anchor:

- It recomputes the sphere ID from the parameters, and the digest from the state's fields and the report's domain.
- It checks that the balances conserve the deposits.
- It requires exactly one valid signature per signer, in signer order: 65 bytes, low `s`, `v` in {0, 1, 27, 28},
  recovering to the signer.
- Any change to a sample fails: a single balance, a missing signature, swapped signers, or a high-`s` copy of a
  signature. Its unit tests cover each case.

## Results

From [`reports/m1max-secp256k1-2party.json`](../reports/m1max-secp256k1-2party.json):

| Machine | Keys | Spheres × parties | Peak | Sustained (65 s) | Per core |
|---|---|---|---|---|---|
| Apple M1 Max, 10 cores | secp256k1 | 1,024 × 2 | 48,061 tx/s | **46,688 tx/s** | about 4,700 |

Each two-party update costs two signatures and two verifications, so a core does roughly 9,300 signature
operations per second here, using go-ethereum's libsecp256k1 binding, with no batching.

## Scaling

Spheres are independent, so throughput grows almost linearly with machines. At the measured rate:

| Target | Machines like this one |
|---|---|
| 1M effective tx/s | about 22 |
| 6M effective tx/s (Sui's July 2026 peak) | about 130 |
| 40M effective tx/s | about 860 |

A faster signature path (for example, verifying several signatures at once) would lower those numbers without
changing the protocol. It is not implemented here; the figures above are what this harness measures today.

## Making a public claim

The reports in this repository are **offline runs**: no sphere was opened or settled on an anchor ledger, so
`settlementTxIds` is empty and the report says so. A public throughput claim under the HIP's rule must also:

1. open every sphere on a real anchor ledger and list those transaction IDs,
2. settle every sphere and list those transaction IDs,
3. publish the report with its samples, so anyone can run `lsverify` on it,
4. ideally, have an independent party watch the run.
