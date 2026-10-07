# Contributing to Lightsphere

Thank you for helping. Lightsphere is Apache-2.0 licensed and follows the contribution practices of the Hiero and
CLPR projects: Developer Certificate of Origin sign-off and review before merge. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Where to start

- **Questions about the protocol:** the HIP discussion,
  [hiero-improvement-proposals#1562](https://github.com/hiero-ledger/hiero-improvement-proposals/discussions/1562).
- **Bugs:** an issue with the commit, the command and the output. A failing test is ideal.
- **Design changes** (state encoding, message formats, dispute or exit rules, trust model): open a design proposal
  issue first. Anything that changes behaviour other implementations would see must also go to the HIP, so
  implementations stay compatible.

## Developer Certificate of Origin (DCO)

Every commit must be signed off. The sign-off certifies the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that you wrote the change or have the
right to submit it under the project's licence, and that your contribution and sign-off are public and kept
permanently. Use your real name and an e-mail address you control.

```bash
git commit -s -m "fix(anchor): ..."
```

To sign off commits already on your branch: `git rebase --signoff main`. If a tool or assistant helped write a
commit, keep your own `Signed-off-by` (you certify the DCO) and add a `Co-Authored-By:` trailer for the tool.
Signed commits (`git commit -S`, GPG or SSH) are encouraged and are used for every maintainer commit.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`. Scopes in use: `anchor`,
`gateway`, `types`, `harness`, `client`, `watchtower`, `vectors`, `docs`, `brand`, `ci`.

## Before you open a pull request

```bash
git submodule update --init --recursive
make check
```

`make check` runs `forge fmt --check`, the contract build with size checks, the Foundry suite, gofmt, `go vet`,
`go test`, and the client's typecheck and tests (including the anvil end-to-end test). CI also runs the fuzz tests
at 10,000 runs, a short benchmark of both key types, and CodeQL.

## Rules for changes

- **Conservation is not negotiable.** Any change to network mode must keep `testFuzz_haltConservesFunds` passing:
  after a halt, an honest sphere's payouts equal its deposits exactly. If you change the operations it can take,
  extend the fuzz test too.
- **One encoding, three implementations.** A change to `SphereState`, the EIP-712 domain, `SphereParams` or the
  network-mode messages updates Solidity, Go and TypeScript together, regenerates the vectors (`make vectors`),
  and keeps all three vector tests passing.
- **Numbers are measured.** Gas, sizes and throughput in the docs come from a test or a committed report.
- **No secrets.** No private keys (other than anvil's published development keys and the fixed test keys in the
  vectors), tokens, internal hostnames or local paths in committed files.
- **Docs.** Update the relevant page in `docs/` and add a line under "Unreleased" in `CHANGELOG.md`.

## Reporting security issues

Do not open an issue or pull request. Follow [SECURITY.md](SECURITY.md).

## Licence

By contributing you agree that your contributions are licensed under the Apache License 2.0 ([LICENSE](LICENSE)).
