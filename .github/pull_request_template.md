## What and why

<!-- One paragraph. Link the issue, or the HIP section this follows. -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`, see CONTRIBUTING.md) and uses Conventional Commits.
- [ ] `make check` passes (forge fmt, build and test; gofmt, go vet and go test; client typecheck and tests).
- [ ] Contract changes keep `testFuzz_haltConservesFunds` passing and add tests for the behaviour they change.
- [ ] Changes to the state encoding or message formats update the vectors and all three implementations.
- [ ] Spec-visible changes are reflected in the HIP (hiero-ledger/hiero-improvement-proposals#1563).
- [ ] Docs updated (README, docs/, CHANGELOG.md under "Unreleased").
- [ ] No secrets, private keys (other than anvil's published development keys), internal hostnames or local paths.

Security issues: do not open a PR. Report privately (SECURITY.md).
