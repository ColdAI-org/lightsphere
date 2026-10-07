# Common tasks. `make check` runs what CI runs.
.PHONY: check contracts harness client fuzz bench vectors brand

check: contracts harness client

contracts:
	cd contracts && forge fmt --check && forge build --sizes --skip 'test/**' && forge test

fuzz:
	cd contracts && FOUNDRY_FUZZ_RUNS=10000 forge test --match-test testFuzz

harness:
	cd harness && test -z "$$(gofmt -l .)" && go vet ./... && go test ./...

client: contracts
	cd ts && npm ci && npm run abi && npm run typecheck && npm test

# A conforming 70-second run on this machine, verified afterwards.
bench:
	cd harness && go run ./cmd/lsbench -duration 70s -out ../reports/local.json && go run ./cmd/lsverify ../reports/local.json

# Regenerate the cross-language vectors (then run all three test suites).
vectors:
	cd harness && go run ./cmd/lsvectors -out ../contracts/test/vectors/signed-v1.json

brand:
	cd tools/brand && npm install && npm run render
