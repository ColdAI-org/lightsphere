# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting: the **Security** tab of this
repository, then **Report a vulnerability**
([direct link](https://github.com/ColdAI-org/lightsphere/security/advisories/new)). Do not open a public issue,
pull request or discussion.

Please include the affected file and commit, a description, the impact you expect, and a proof of concept. A
Foundry test is ideal, especially one that breaks `testFuzz_haltConservesFunds` or a signed-mode invariant.

We aim to acknowledge within 3 working days, give a first assessment within 10 working days, and agree a
disclosure date with you. We credit reporters who want credit.

If the issue is in the Lightsphere **specification** rather than this implementation, report it here as well. We
coordinate the fix to the HIP (hiero-ledger/hiero-improvement-proposals#1563) so other implementations are not left
exposed.

## Scope

| In scope | Out of scope |
|---|---|
| `contracts/src/` (anchor, gateway, types, interfaces) | `contracts/lib/` (forge-std, OpenZeppelin): report upstream |
| `harness/state/` (digest, sphere ID, signing) | Mocks and test helpers in `contracts/test/` |
| `ts/src/` (client and watchtower) | The CLPR Service and verifiers: report to LFDT-CLPR |
| CI workflows in `.github/` | Hedera system contracts: report to Hiero |
| | Denial of service by volume, social engineering |

The trust model, the invariants and the known limitations are in [docs/security.md](docs/security.md). An issue
listed there as a known limitation is in scope only if you show a worse impact than described.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes. Local networks and testnets only. Not deployed on any mainnet, not audited |
