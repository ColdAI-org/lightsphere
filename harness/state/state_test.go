package state

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

type vectorFile struct {
	ChainID           uint64   `json:"chainId"`
	VerifyingContract string   `json:"verifyingContract"`
	DomainSeparator   string   `json:"domainSeparator"`
	Participants      []string `json:"participants"`
	Signers           []string `json:"signers"`
	JoinSignatures    []string `json:"joinSignatures"`
	PrivateKeys       []string `json:"privateKeys"`
	Assets            []string `json:"assets"`
	InitialDeposits   []string `json:"initialDeposits"`
	ChallengePeriod   uint64   `json:"challengePeriod"`
	FundingDeadline   uint64   `json:"fundingDeadline"`
	Salt              string   `json:"salt"`
	SphereID          string   `json:"sphereId"`
	States            []struct {
		SphereID    string   `json:"sphereId"`
		Version     uint64   `json:"version"`
		Balances    []string `json:"balances"`
		AppDataHash string   `json:"appDataHash"`
		IsFinal     bool     `json:"isFinal"`
		Digest      string   `json:"digest"`
		Signatures  []string `json:"signatures"`
	} `json:"states"`
}

func b32(t *testing.T, s string) (out [32]byte) {
	t.Helper()
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil || len(b) != 32 {
		t.Fatalf("bad bytes32 %q", s)
	}
	copy(out[:], b)
	return
}

func bigs(ss []string) (out []*big.Int) {
	for _, s := range ss {
		v, _ := new(big.Int).SetString(s, 10)
		out = append(out, v)
	}
	return
}

// The committed vectors are also checked by contracts/test/Vectors.t.sol and ts/test/vectors.test.ts.
func TestVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/test/vectors/signed-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectorFile
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	dom := NewDomain(v.ChainID, common.HexToAddress(v.VerifyingContract))
	if sep := dom.Separator(); sep != b32(t, v.DomainSeparator) {
		t.Fatalf("domain separator %x", sep)
	}
	p := &SphereParams{InitialDeposits: bigs(v.InitialDeposits), ChallengePeriod: v.ChallengePeriod,
		FundingDeadline: v.FundingDeadline, Salt: b32(t, v.Salt)}
	for _, a := range v.Participants {
		p.Participants = append(p.Participants, common.HexToAddress(a))
	}
	for _, a := range v.Signers {
		p.Signers = append(p.Signers, common.HexToAddress(a))
	}
	for _, a := range v.Assets {
		p.Assets = append(p.Assets, common.HexToAddress(a))
	}
	sid, err := dom.SphereID(p)
	if err != nil || sid != b32(t, v.SphereID) {
		t.Fatalf("sphereId %x err %v", sid, err)
	}
	for j, k := range v.PrivateKeys {
		key, _ := crypto.HexToECDSA(strings.TrimPrefix(k, "0x"))
		sig, err := SignECDSA(key, dom.JoinDigest(sid, p.Participants[j]))
		if err != nil || "0x"+hex.EncodeToString(sig) != v.JoinSignatures[j] {
			t.Fatalf("join signature %d differs", j)
		}
	}
	for i, js := range v.States {
		s := &SphereState{SphereID: b32(t, js.SphereID), Version: js.Version, Balances: bigs(js.Balances),
			AppDataHash: b32(t, js.AppDataHash), IsFinal: js.IsFinal}
		dg := dom.Digest(s)
		if dg != b32(t, js.Digest) {
			t.Fatalf("state %d digest %x", i, dg)
		}
		for j, k := range v.PrivateKeys {
			key, _ := crypto.HexToECDSA(strings.TrimPrefix(k, "0x"))
			sig, err := SignECDSA(key, dg)
			if err != nil || "0x"+hex.EncodeToString(sig) != js.Signatures[j] {
				t.Fatalf("state %d signer %d: signature differs", i, j)
			}
			if !VerifyECDSA(crypto.CompressPubkey(&key.PublicKey), dg, sig) {
				t.Fatalf("state %d signer %d: does not verify", i, j)
			}
		}
	}
}

func TestDigestBindsEveryField(t *testing.T) {
	dom := NewDomain(296, common.HexToAddress("0x01"))
	base := SphereState{Version: 7, Balances: []*big.Int{big.NewInt(1), big.NewInt(2)}}
	d0 := dom.Digest(&base)
	mutations := map[string]func(s *SphereState){
		"sphereId":    func(s *SphereState) { s.SphereID[0] = 1 },
		"version":     func(s *SphereState) { s.Version++ },
		"balances":    func(s *SphereState) { s.Balances = []*big.Int{big.NewInt(2), big.NewInt(1)} },
		"appDataHash": func(s *SphereState) { s.AppDataHash[31] = 1 },
		"isFinal":     func(s *SphereState) { s.IsFinal = true },
	}
	for name, m := range mutations {
		s := base
		s.Balances = []*big.Int{big.NewInt(1), big.NewInt(2)}
		m(&s)
		if dom.Digest(&s) == d0 {
			t.Errorf("digest ignores %s", name)
		}
	}
	if NewDomain(295, common.HexToAddress("0x01")).Digest(&base) == d0 {
		t.Error("digest ignores chain id")
	}
}

func TestTransferRejectsOverdraft(t *testing.T) {
	bal := []*big.Int{big.NewInt(5), big.NewInt(0)}
	if err := Transfer(bal, 1, 0, 0, 1, big.NewInt(6)); err == nil {
		t.Fatal("overdraft accepted")
	}
	if err := Transfer(bal, 1, 0, 0, 1, big.NewInt(5)); err != nil || bal[1].Int64() != 5 || bal[0].Sign() != 0 {
		t.Fatal("transfer wrong")
	}
}
