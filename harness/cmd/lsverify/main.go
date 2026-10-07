// Command lsverify re-checks the sampled states in an lsbench report, exactly as the anchor contract would:
// it recomputes each sphere ID from the sample's parameters, recomputes the EIP-712 digest from the state's
// fields and the report's domain, checks that balances conserve the deposits, and requires one valid low-s
// secp256k1 signature per signer, in signer order.
package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/ColdAI-org/lightsphere/harness/state"
)

type params struct {
	Participants    []string `json:"participants"`
	Signers         []string `json:"signers"`
	Assets          []string `json:"assets"`
	InitialDeposits []string `json:"initialDeposits"`
	ChallengePeriod uint64   `json:"challengePeriod"`
	FundingDeadline uint64   `json:"fundingDeadline"`
	Salt            string   `json:"salt"`
}

type sample struct {
	Params      params   `json:"params"`
	SphereID    string   `json:"sphereId"`
	Version     uint64   `json:"version"`
	Balances    []string `json:"balances"`
	AppDataHash string   `json:"appDataHash"`
	IsFinal     bool     `json:"isFinal"`
	Digest      string   `json:"digest"`
	Signatures  []string `json:"signatures"`
}

type report struct {
	KeyType        string   `json:"keyType"`
	ChainID        uint64   `json:"chainId"`
	AnchorContract string   `json:"anchorContract"`
	Samples        []sample `json:"samples"`
}

var halfN, _ = new(big.Int).SetString("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0", 16)

func b32(s string) ([32]byte, error) {
	var out [32]byte
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil || len(b) != 32 {
		return out, fmt.Errorf("not 32 bytes: %q", s)
	}
	copy(out[:], b)
	return out, nil
}

func bigs(ss []string) ([]*big.Int, error) {
	var out []*big.Int
	for _, s := range ss {
		v, ok := new(big.Int).SetString(s, 10)
		if !ok || v.Sign() < 0 {
			return nil, fmt.Errorf("bad amount %q", s)
		}
		out = append(out, v)
	}
	return out, nil
}

func addrs(ss []string) ([]common.Address, error) {
	var out []common.Address
	for _, s := range ss {
		if !common.IsHexAddress(s) {
			return nil, fmt.Errorf("bad address %q", s)
		}
		out = append(out, common.HexToAddress(s))
	}
	return out, nil
}

// signerOf returns the address that produced a 65-byte r||s||v signature, applying the anchor's rules.
func signerOf(digest [32]byte, sig []byte) (common.Address, error) {
	if len(sig) != 65 {
		return common.Address{}, errors.New("signature is not 65 bytes")
	}
	v := sig[64]
	if v >= 27 {
		v -= 27
	}
	if v > 1 {
		return common.Address{}, errors.New("v out of range")
	}
	if new(big.Int).SetBytes(sig[32:64]).Cmp(halfN) > 0 {
		return common.Address{}, errors.New("high s")
	}
	pub, err := crypto.SigToPub(digest[:], append(append([]byte{}, sig[:64]...), v))
	if err != nil {
		return common.Address{}, err
	}
	return crypto.PubkeyToAddress(*pub), nil
}

func check(dom *state.Domain, smp sample) error {
	p := &state.SphereParams{ChallengePeriod: smp.Params.ChallengePeriod, FundingDeadline: smp.Params.FundingDeadline}
	var err error
	if p.Participants, err = addrs(smp.Params.Participants); err != nil {
		return err
	}
	if p.Signers, err = addrs(smp.Params.Signers); err != nil {
		return err
	}
	if p.Assets, err = addrs(smp.Params.Assets); err != nil {
		return err
	}
	if p.InitialDeposits, err = bigs(smp.Params.InitialDeposits); err != nil {
		return err
	}
	if p.Salt, err = b32(smp.Params.Salt); err != nil {
		return err
	}
	nP, nA := len(p.Participants), len(p.Assets)
	if nP < 2 || len(p.Signers) != nP || nA == 0 || len(p.InitialDeposits) != nP*nA {
		return errors.New("malformed parameters")
	}
	sid, err := dom.SphereID(p)
	if err != nil {
		return err
	}
	if want, err := b32(smp.SphereID); err != nil || want != sid {
		return errors.New("sphere ID does not match its parameters")
	}

	s := &state.SphereState{SphereID: sid, Version: smp.Version, IsFinal: smp.IsFinal}
	if s.AppDataHash, err = b32(smp.AppDataHash); err != nil {
		return err
	}
	if s.Balances, err = bigs(smp.Balances); err != nil {
		return err
	}
	if len(s.Balances) != nP*nA {
		return errors.New("wrong number of balances")
	}
	for a := 0; a < nA; a++ {
		want, got := new(big.Int), new(big.Int)
		for i := 0; i < nP; i++ {
			want.Add(want, p.InitialDeposits[i*nA+a])
			got.Add(got, s.Balances[i*nA+a])
		}
		if want.Cmp(got) != 0 {
			return errors.New("balances do not conserve the deposits")
		}
	}
	dg := dom.Digest(s)
	if "0x"+hex.EncodeToString(dg[:]) != strings.ToLower(smp.Digest) {
		return errors.New("digest does not match the state")
	}
	if len(smp.Signatures) != nP {
		return fmt.Errorf("%d signatures for %d signers", len(smp.Signatures), nP)
	}
	for i, h := range smp.Signatures {
		sig, err := hex.DecodeString(strings.TrimPrefix(h, "0x"))
		if err != nil {
			return fmt.Errorf("signature %d: %v", i, err)
		}
		got, err := signerOf(dg, sig)
		if err != nil {
			return fmt.Errorf("signature %d: %v", i, err)
		}
		if got != p.Signers[i] {
			return fmt.Errorf("signature %d is not from signer %s", i, p.Signers[i].Hex())
		}
	}
	return nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: lsverify report.json")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var r report
	if err := json.Unmarshal(raw, &r); err != nil {
		fmt.Fprintln(os.Stderr, "not a report:", err)
		os.Exit(2)
	}
	if r.KeyType != "secp256k1" {
		fmt.Fprintf(os.Stderr, "unsupported key type %q\n", r.KeyType)
		os.Exit(1)
	}
	if len(r.Samples) == 0 {
		fmt.Fprintln(os.Stderr, "report has no samples")
		os.Exit(1)
	}
	if !common.IsHexAddress(r.AnchorContract) {
		fmt.Fprintln(os.Stderr, "bad anchor address")
		os.Exit(1)
	}
	dom := state.NewDomain(r.ChainID, common.HexToAddress(r.AnchorContract))
	bad := 0
	for i, smp := range r.Samples {
		if err := check(dom, smp); err != nil {
			bad++
			fmt.Printf("sample %d (sphere %s v%d): FAIL: %v\n", i, smp.SphereID, smp.Version, err)
		}
	}
	fmt.Printf("%d/%d sampled states verified\n", len(r.Samples)-bad, len(r.Samples))
	if bad != 0 {
		os.Exit(1)
	}
}
