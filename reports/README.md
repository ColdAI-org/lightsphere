# Benchmark reports

Each file is an `lsbench` report. Verify one with:

```bash
cd ../harness && go run ./cmd/lsverify ../reports/m1max-secp256k1-2party.json
```

| Report | Machine | Keys | Spheres × parties | Peak | Sustained | Window |
|---|---|---|---|---|---|---|
| [`m1max-secp256k1-2party.json`](m1max-secp256k1-2party.json) | Apple M1 Max, 10 cores | secp256k1 | 1,024 × 2 | 48,061 tx/s | 46,688 tx/s | 65 s (conforming) |

These are offline runs: no sphere was opened or settled on an anchor ledger, so `settlementTxIds` is empty. See
[docs/benchmarking.md](../docs/benchmarking.md#making-a-public-claim) for what a public claim also needs.
