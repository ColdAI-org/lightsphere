// Package state implements the Lightsphere signed-mode state encoding: the EIP-712 domain and
// SphereState digest, sphere IDs, and ECDSA / ED25519 signing that the anchor contract accepts.
package state

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	sphereStateTypeHash = crypto.Keccak256(
		[]byte("SphereState(bytes32 sphereId,uint64 version,uint256[] balances,bytes32 appDataHash,bool isFinal)"))
	domainTypeHash = crypto.Keccak256(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	nameHash    = crypto.Keccak256([]byte("Lightsphere"))
	versionHash = crypto.Keccak256([]byte("1"))
)

// Domain identifies one anchor contract on one Hiero network.
type Domain struct {
	ChainID           uint64
	VerifyingContract common.Address
	separator         [32]byte
}

func NewDomain(chainID uint64, anchor common.Address) *Domain {
	d := &Domain{ChainID: chainID, VerifyingContract: anchor}
	buf := make([]byte, 0, 5*32)
	buf = append(buf, domainTypeHash...)
	buf = append(buf, nameHash...)
	buf = append(buf, versionHash...)
	buf = append(buf, common.LeftPadBytes(new(big.Int).SetUint64(chainID).Bytes(), 32)...)
	buf = append(buf, common.LeftPadBytes(anchor.Bytes(), 32)...)
	copy(d.separator[:], crypto.Keccak256(buf))
	return d
}

func (d *Domain) Separator() [32]byte { return d.separator }

// SphereState mirrors LightsphereTypes.SphereState. Balances are participant-major.
type SphereState struct {
	SphereID    [32]byte
	Version     uint64
	Balances    []*big.Int
	AppDataHash [32]byte
	IsFinal     bool
}

// Digest is the EIP-712 digest every participant signs.
func (d *Domain) Digest(s *SphereState) [32]byte {
	var scratch [32]byte
	packed := make([]byte, 32*len(s.Balances))
	for i, b := range s.Balances {
		b.FillBytes(packed[i*32 : (i+1)*32])
	}
	buf := make([]byte, 0, 6*32)
	buf = append(buf, sphereStateTypeHash...)
	buf = append(buf, s.SphereID[:]...)
	binary.BigEndian.PutUint64(scratch[24:], s.Version)
	buf = append(buf, scratch[:]...)
	buf = append(buf, crypto.Keccak256(packed)...)
	buf = append(buf, s.AppDataHash[:]...)
	var final [32]byte
	if s.IsFinal {
		final[31] = 1
	}
	buf = append(buf, final[:]...)
	structHash := crypto.Keccak256(buf)

	msg := make([]byte, 0, 66)
	msg = append(msg, 0x19, 0x01)
	msg = append(msg, d.separator[:]...)
	msg = append(msg, structHash...)
	var out [32]byte
	copy(out[:], crypto.Keccak256(msg))
	return out
}

// SignECDSA returns r||s||v with v in {27,28}; go-ethereum always produces low-s signatures.
func SignECDSA(key *ecdsa.PrivateKey, digest [32]byte) ([]byte, error) {
	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return nil, err
	}
	sig[64] += 27
	return sig, nil
}

// VerifyECDSA checks a 65-byte signature against a 33- or 65-byte public key.
func VerifyECDSA(pub []byte, digest [32]byte, sig []byte) bool {
	if len(sig) != 65 {
		return false
	}
	return crypto.VerifySignature(pub, digest[:], sig[:64])
}

// SignED25519 signs the 32-byte digest, as Hedera ED25519 accounts do for isAuthorizedRaw.
func SignED25519(key ed25519.PrivateKey, digest [32]byte) []byte {
	return ed25519.Sign(key, digest[:])
}

func VerifyED25519(pub ed25519.PublicKey, digest [32]byte, sig []byte) bool {
	return len(sig) == 64 && ed25519.Verify(pub, digest[:], sig)
}

// SphereParams mirrors LightsphereTypes.SphereParams; field names match the ABI tuple components.
type SphereParams struct {
	Mode            uint8
	Participants    []common.Address
	Assets          []common.Address
	InitialDeposits []*big.Int
	ChallengePeriod uint64
	FundingDeadline uint64
	NetworkConfig   []byte
	Salt            [32]byte
}

var paramsArgs abi.Arguments

func init() {
	tuple, err := abi.NewType("tuple", "", []abi.ArgumentMarshaling{
		{Name: "mode", Type: "uint8"},
		{Name: "participants", Type: "address[]"},
		{Name: "assets", Type: "address[]"},
		{Name: "initialDeposits", Type: "uint256[]"},
		{Name: "challengePeriod", Type: "uint64"},
		{Name: "fundingDeadline", Type: "uint64"},
		{Name: "networkConfig", Type: "bytes"},
		{Name: "salt", Type: "bytes32"},
	})
	if err != nil {
		panic(err)
	}
	u256, _ := abi.NewType("uint256", "", nil)
	addr, _ := abi.NewType("address", "", nil)
	paramsArgs = abi.Arguments{{Type: u256}, {Type: addr}, {Type: tuple}}
}

// SphereID = keccak256(abi.encode(chainId, anchor, params)).
func (d *Domain) SphereID(p *SphereParams) ([32]byte, error) {
	if p.NetworkConfig == nil {
		p.NetworkConfig = []byte{}
	}
	enc, err := paramsArgs.Pack(new(big.Int).SetUint64(d.ChainID), d.VerifyingContract, *p)
	if err != nil {
		return [32]byte{}, err
	}
	var id [32]byte
	copy(id[:], crypto.Keccak256(enc))
	return id, nil
}

// Transfer moves amount of asset a from participant `from` to `to` in a participant-major balance vector.
func Transfer(bal []*big.Int, nAssets, a, from, to int, amount *big.Int) error {
	src := bal[from*nAssets+a]
	if src.Cmp(amount) < 0 {
		return errors.New("insufficient balance")
	}
	src.Sub(src, amount)
	bal[to*nAssets+a].Add(bal[to*nAssets+a], amount)
	return nil
}
