// Command lsvectors writes deterministic signed-mode vectors (domain, params, sphereId, states, digests,
// signatures) that the Solidity and TypeScript test suites check against.
package main

import (
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/ColdAI-org/lightsphere/harness/state"
)

type jsonState struct {
	SphereID    string   `json:"sphereId"`
	Version     uint64   `json:"version"`
	Balances    []string `json:"balances"`
	AppDataHash string   `json:"appDataHash"`
	IsFinal     bool     `json:"isFinal"`
	Digest      string   `json:"digest"`
	Signatures  []string `json:"signatures"`
}

type vectors struct {
	ChainID           uint64      `json:"chainId"`
	VerifyingContract string      `json:"verifyingContract"`
	DomainSeparator   string      `json:"domainSeparator"`
	Participants      []string    `json:"participants"`
	Signers           []string    `json:"signers"`
	JoinSignatures    []string    `json:"joinSignatures"`
	PrivateKeys       []string    `json:"privateKeys"`
	Assets            []string    `json:"assets"`
	InitialDeposits   []string    `json:"initialDeposits"`
	ChallengePeriod   uint64      `json:"challengePeriod"`
	FundingDeadline   uint64      `json:"fundingDeadline"`
	Salt              string      `json:"salt"`
	SphereID          string      `json:"sphereId"`
	States            []jsonState `json:"states"`
}

func hx(b []byte) string { return "0x" + hex.EncodeToString(b) }

func main() {
	out := flag.String("out", "vectors.json", "output file")
	flag.Parse()

	anchor := common.HexToAddress("0x00000000000000000000000000000000004c5350") // fixed test anchor
	dom := state.NewDomain(296, anchor)                                         // Hedera testnet
	keyHex := []string{
		"0x00000000000000000000000000000000000000000000000000000000000a11ce",
		"0x0000000000000000000000000000000000000000000000000000000000000b0b",
	}
	v := vectors{ChainID: dom.ChainID, VerifyingContract: anchor.Hex(), PrivateKeys: keyHex, ChallengePeriod: 3600, FundingDeadline: 4102444800}
	sep := dom.Separator()
	v.DomainSeparator = hx(sep[:])

	p := &state.SphereParams{
		Mode:            0,
		Assets:          []common.Address{{}, common.HexToAddress("0x0000000000000000000000000000000000456789")},
		InitialDeposits: []*big.Int{big.NewInt(10e8), big.NewInt(100), big.NewInt(5e8), big.NewInt(50)},
		ChallengePeriod: v.ChallengePeriod,
		FundingDeadline: v.FundingDeadline,
	}
	copy(p.Salt[:], crypto.Keccak256([]byte("lightsphere-vectors")))
	v.Salt = hx(p.Salt[:])
	privs := make([]*ecdsa.PrivateKey, len(keyHex))
	for i, k := range keyHex {
		pk, err := crypto.HexToECDSA(k[2:])
		if err != nil {
			panic(err)
		}
		privs[i] = pk
		addr := crypto.PubkeyToAddress(pk.PublicKey)
		p.Participants = append(p.Participants, addr)
		p.Signers = append(p.Signers, addr)
		v.Participants = append(v.Participants, addr.Hex())
		v.Signers = append(v.Signers, addr.Hex())
	}
	for _, a := range p.Assets {
		v.Assets = append(v.Assets, a.Hex())
	}
	for _, d := range p.InitialDeposits {
		v.InitialDeposits = append(v.InitialDeposits, d.String())
	}
	sid, err := dom.SphereID(p)
	if err != nil {
		panic(err)
	}
	v.SphereID = hx(sid[:])
	for i, k := range privs {
		sig, err := state.SignECDSA(k, dom.JoinDigest(sid, p.Participants[i]))
		if err != nil {
			panic(err)
		}
		v.JoinSignatures = append(v.JoinSignatures, hx(sig))
	}

	bal := []*big.Int{big.NewInt(10e8), big.NewInt(100), big.NewInt(5e8), big.NewInt(50)}
	for _, step := range []struct {
		version uint64
		final   bool
	}{{1, false}, {41, false}, {1_000_000, true}} {
		_ = state.Transfer(bal, 2, 0, 0, 1, big.NewInt(1e7)) // Alice pays Bob 0.1 HBAR per step
		_ = state.Transfer(bal, 2, 1, 1, 0, big.NewInt(3))   // Bob pays Alice 3 MCK per step
		s := &state.SphereState{SphereID: sid, Version: step.version, IsFinal: step.final}
		for _, b := range bal {
			s.Balances = append(s.Balances, new(big.Int).Set(b))
		}
		copy(s.AppDataHash[:], crypto.Keccak256([]byte(fmt.Sprintf("app-%d", step.version))))
		dg := dom.Digest(s)
		js := jsonState{SphereID: hx(sid[:]), Version: s.Version, AppDataHash: hx(s.AppDataHash[:]), IsFinal: s.IsFinal, Digest: hx(dg[:])}
		for _, b := range s.Balances {
			js.Balances = append(js.Balances, b.String())
		}
		for _, k := range privs {
			sig, err := state.SignECDSA(k, dg)
			if err != nil {
				panic(err)
			}
			js.Signatures = append(js.Signatures, hx(sig))
		}
		v.States = append(v.States, js)
	}

	b, _ := json.MarshalIndent(v, "", "  ")
	if err := os.WriteFile(*out, append(b, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Println("wrote", *out)
}
