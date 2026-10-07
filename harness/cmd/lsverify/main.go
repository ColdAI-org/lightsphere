// Command lsverify re-checks the sampled states in an lsbench report: it recomputes every EIP-712 digest
// from the state fields and the report's domain, and verifies each signature against its signer.
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/shayansal/lightsphere/harness/state"
)

type sample struct {
	SphereID    string   `json:"sphereId"`
	Version     uint64   `json:"version"`
	Balances    []string `json:"balances"`
	AppDataHash string   `json:"appDataHash"`
	IsFinal     bool     `json:"isFinal"`
	Digest      string   `json:"digest"`
	Signers     []string `json:"signers"`
	Signatures  []string `json:"signatures"`
}

type report struct {
	KeyType        string   `json:"keyType"`
	ChainID        uint64   `json:"chainId"`
	AnchorContract string   `json:"anchorContract"`
	Samples        []sample `json:"samples"`
}

func unhex(s string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		panic(err)
	}
	return b
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: lsverify report.json")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var r report
	if err := json.Unmarshal(raw, &r); err != nil {
		panic(err)
	}
	dom := state.NewDomain(r.ChainID, common.HexToAddress(r.AnchorContract))
	bad := 0
	for i, smp := range r.Samples {
		s := &state.SphereState{Version: smp.Version, IsFinal: smp.IsFinal}
		copy(s.SphereID[:], unhex(smp.SphereID))
		copy(s.AppDataHash[:], unhex(smp.AppDataHash))
		for _, b := range smp.Balances {
			v, _ := new(big.Int).SetString(b, 10)
			s.Balances = append(s.Balances, v)
		}
		dg := dom.Digest(s)
		ok := "0x"+hex.EncodeToString(dg[:]) == smp.Digest
		for j, sig := range smp.Signatures {
			sb := unhex(sig)
			switch r.KeyType {
			case "ed25519":
				ok = ok && state.VerifyED25519(unhex(smp.Signers[j]), dg, sb)
			default:
				pub, err := crypto.SigToPub(dg[:], append(sb[:64:64], sb[64]-27))
				ok = ok && err == nil && crypto.PubkeyToAddress(*pub) == common.HexToAddress(smp.Signers[j])
			}
		}
		if !ok {
			bad++
			fmt.Printf("sample %d (sphere %s v%d): FAIL\n", i, smp.SphereID, smp.Version)
		}
	}
	fmt.Printf("%d/%d sampled states verified\n", len(r.Samples)-bad, len(r.Samples))
	if bad != 0 {
		os.Exit(1)
	}
}
