package main

import (
	"crypto/ecdsa"
	"encoding/hex"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/ColdAI-org/lightsphere/harness/state"
)

func h(b []byte) string { return "0x" + hex.EncodeToString(b) }

// validSample builds a correct two-party sample signed for dom.
func validSample(t *testing.T, dom *state.Domain) sample {
	t.Helper()
	keys := []*ecdsa.PrivateKey{}
	var who []common.Address
	for i := 0; i < 2; i++ {
		k, err := crypto.GenerateKey()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, k)
		who = append(who, crypto.PubkeyToAddress(k.PublicKey))
	}
	p := &state.SphereParams{Participants: who, Signers: who, Assets: []common.Address{{}},
		InitialDeposits: []*big.Int{big.NewInt(10), big.NewInt(10)}, ChallengePeriod: 3600, FundingDeadline: 4102444800}
	sid, err := dom.SphereID(p)
	if err != nil {
		t.Fatal(err)
	}
	s := &state.SphereState{SphereID: sid, Version: 7, Balances: []*big.Int{big.NewInt(4), big.NewInt(16)}}
	dg := dom.Digest(s)
	smp := sample{
		Params: params{Participants: []string{who[0].Hex(), who[1].Hex()}, Signers: []string{who[0].Hex(), who[1].Hex()},
			Assets: []string{common.Address{}.Hex()}, InitialDeposits: []string{"10", "10"},
			ChallengePeriod: 3600, FundingDeadline: 4102444800, Salt: h(p.Salt[:])},
		SphereID: h(sid[:]), Version: 7, Balances: []string{"4", "16"}, AppDataHash: h(s.AppDataHash[:]), Digest: h(dg[:]),
	}
	for _, k := range keys {
		sig, err := state.SignECDSA(k, dg)
		if err != nil {
			t.Fatal(err)
		}
		smp.Signatures = append(smp.Signatures, h(sig))
	}
	return smp
}

func TestCheck(t *testing.T) {
	dom := state.NewDomain(296, common.HexToAddress("0x4c5350"))
	if err := check(dom, validSample(t, dom)); err != nil {
		t.Fatalf("valid sample rejected: %v", err)
	}

	cases := map[string]func(s *sample){
		"no signatures":         func(s *sample) { s.Signatures = nil },
		"one signature missing": func(s *sample) { s.Signatures = s.Signatures[:1] },
		"signers swapped":       func(s *sample) { s.Signatures[0], s.Signatures[1] = s.Signatures[1], s.Signatures[0] },
		"balance changed":       func(s *sample) { s.Balances[0] = "5"; s.Balances[1] = "15" },
		"funds created":         func(s *sample) { s.Balances[0] = "5" },
		"version changed":       func(s *sample) { s.Version++ },
		"sphere ID not from params": func(s *sample) {
			s.SphereID = "0x" + strings.Repeat("11", 32)
		},
		"short signature": func(s *sample) { s.Signatures[1] = s.Signatures[1][:20] },
		"high s": func(s *sample) {
			raw, _ := hex.DecodeString(strings.TrimPrefix(s.Signatures[1], "0x"))
			n, _ := new(big.Int).SetString("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16)
			sv := new(big.Int).Sub(n, new(big.Int).SetBytes(raw[32:64]))
			sv.FillBytes(raw[32:64])
			raw[64] ^= 1 // flip parity, which also flips 27 <-> 28
			s.Signatures[1] = h(raw)
		},
	}
	for name, mutate := range cases {
		smp := validSample(t, dom)
		mutate(&smp)
		if err := check(dom, smp); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	other := state.NewDomain(295, common.HexToAddress("0x4c5350"))
	if err := check(other, validSample(t, dom)); err == nil {
		t.Error("sample accepted under another chain id")
	}
}
