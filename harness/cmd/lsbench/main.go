// Command lsbench measures signed-mode Lightsphere throughput as the Lightsphere HIP defines it.
//
// One effective transaction is a SphereState with a new version that every participant has signed and
// every other participant has verified. Each worker goroutine owns a set of spheres and runs them in a
// loop; nothing is counted until all signatures on a state are checked. The report gives the peak
// one-second rate and the sustained rate averaged over the run (at least 60 seconds for a conforming
// report), plus a random sample of fully signed states for third-party checking.
package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"math/rand"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/shayansal/lightsphere/harness/state"
)

type party struct {
	ecKey *ecdsa.PrivateKey
	ecPub []byte
	edKey ed25519.PrivateKey
	edPub ed25519.PublicKey
	addr  common.Address
}

type sphere struct {
	state   state.SphereState
	parties []party
	nAssets int
}

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
	Definition        string    `json:"definition"`
	KeyType           string    `json:"keyType"`
	Spheres           int       `json:"spheres"`
	ParticipantsEach  int       `json:"participantsPerSphere"`
	Workers           int       `json:"workers"`
	DurationSeconds   float64   `json:"durationSeconds"`
	WarmupSeconds     int       `json:"warmupSeconds"`
	EffectiveTxTotal  uint64    `json:"effectiveTransactions"`
	PeakTPS           uint64    `json:"peakTps"`
	SustainedTPS      float64   `json:"sustainedTps"`
	SustainedWindowOK bool      `json:"sustainedWindowAtLeast60s"`
	PerSecond         []uint64  `json:"perSecond"`
	Hardware          hardware  `json:"hardware"`
	ChainID           uint64    `json:"chainId"`
	AnchorContract    string    `json:"anchorContract"`
	SettlementTxIDs   []string  `json:"settlementTxIds"`
	SettlementNote    string    `json:"settlementNote"`
	Samples           []sample  `json:"samples"`
	StartedAt         time.Time `json:"startedAt"`
}

type hardware struct {
	CPU   string `json:"cpu"`
	Cores int    `json:"logicalCores"`
	OS    string `json:"os"`
	Arch  string `json:"arch"`
	GoVer string `json:"go"`
}

func cpuModel() string {
	if runtime.GOOS == "darwin" {
		if out, err := exec.Command("sysctl", "-n", "machdep.cpu.brand_string").Output(); err == nil {
			return strings.TrimSpace(string(out))
		}
	}
	if b, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "model name") {
				return strings.TrimSpace(strings.SplitN(l, ":", 2)[1])
			}
		}
	}
	return "unknown"
}

func hx(b []byte) string { return "0x" + hex.EncodeToString(b) }

func main() {
	nSpheres := flag.Int("spheres", 1024, "number of concurrent spheres")
	nParties := flag.Int("parties", 2, "participants per sphere (2..16)")
	workers := flag.Int("workers", runtime.NumCPU(), "worker goroutines")
	dur := flag.Duration("duration", 70*time.Second, "measured duration (>= 60s for a conforming report)")
	warmup := flag.Int("warmup", 5, "seconds excluded from the sustained average")
	keyType := flag.String("keys", "ed25519", "ed25519 or ecdsa")
	chainID := flag.Uint64("chain", 296, "anchor ledger EVM chain id")
	anchorHex := flag.String("anchor", "0x00000000000000000000000000000000004c5350", "anchor contract address")
	nSamples := flag.Int("samples", 32, "fully signed states to include in the report")
	out := flag.String("out", "report.json", "report path")
	flag.Parse()
	if *nParties < 2 || *nParties > 16 {
		fmt.Fprintln(os.Stderr, "parties must be 2..16")
		os.Exit(2)
	}
	useEd := *keyType == "ed25519"
	if !useEd && *keyType != "ecdsa" {
		fmt.Fprintln(os.Stderr, "keys must be ed25519 or ecdsa")
		os.Exit(2)
	}

	dom := state.NewDomain(*chainID, common.HexToAddress(*anchorHex))
	spheres := make([]*sphere, *nSpheres)
	for i := range spheres {
		sp := &sphere{nAssets: 1}
		p := &state.SphereParams{Assets: []common.Address{{}}, ChallengePeriod: 3600, FundingDeadline: 4102444800}
		for j := 0; j < *nParties; j++ {
			var pt party
			if useEd {
				pub, priv, _ := ed25519.GenerateKey(nil)
				pt.edKey, pt.edPub = priv, pub
				pt.addr = common.BytesToAddress(crypto.Keccak256(pub)[12:]) // label only
			} else {
				k, _ := crypto.GenerateKey()
				pt.ecKey, pt.ecPub = k, crypto.CompressPubkey(&k.PublicKey)
				pt.addr = crypto.PubkeyToAddress(k.PublicKey)
			}
			sp.parties = append(sp.parties, pt)
			p.Participants = append(p.Participants, pt.addr)
			p.InitialDeposits = append(p.InitialDeposits, big.NewInt(1_000_000_000_000))
		}
		p.Salt[0], p.Salt[1] = byte(i>>8), byte(i)
		sid, err := dom.SphereID(p)
		if err != nil {
			panic(err)
		}
		sp.state = state.SphereState{SphereID: sid}
		for _, d := range p.InitialDeposits {
			sp.state.Balances = append(sp.state.Balances, new(big.Int).Set(d))
		}
		spheres[i] = sp
	}

	var total atomic.Uint64
	var stop atomic.Bool
	var failures atomic.Uint64
	sampleEvery := uint64(1)
	var samplesMu sync.Mutex
	var samples []sample

	var wg sync.WaitGroup
	for w := 0; w < *workers; w++ {
		mine := []*sphere{}
		for i := w; i < len(spheres); i += *workers {
			mine = append(mine, spheres[i])
		}
		if len(mine) == 0 {
			continue
		}
		wg.Add(1)
		go func(mine []*sphere, seed int64) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed))
			one := big.NewInt(1)
			sigs := make([][]byte, *nParties)
			var local uint64
			for !stop.Load() {
				for _, sp := range mine {
					s := &sp.state
					from := rng.Intn(*nParties)
					to := (from + 1 + rng.Intn(*nParties-1)) % *nParties
					_ = state.Transfer(s.Balances, sp.nAssets, 0, from, to, one)
					s.Version++
					s.AppDataHash[0], s.AppDataHash[1] = byte(s.Version), byte(s.Version>>8)
					dg := dom.Digest(s)
					// Every participant signs.
					for j := range sp.parties {
						if useEd {
							sigs[j] = state.SignED25519(sp.parties[j].edKey, dg)
						} else {
							sigs[j], _ = state.SignECDSA(sp.parties[j].ecKey, dg)
						}
					}
					// Every participant verifies every other participant's signature before counting.
					ok := true
					for v := range sp.parties {
						for j := range sp.parties {
							if j == v {
								continue
							}
							if useEd {
								ok = ok && state.VerifyED25519(sp.parties[j].edPub, dg, sigs[j])
							} else {
								ok = ok && state.VerifyECDSA(sp.parties[j].ecPub, dg, sigs[j])
							}
						}
					}
					if !ok {
						failures.Add(1)
						continue
					}
					local++
					if local%64 == 0 {
						total.Add(64)
					}
					if rng.Uint64()%4096 < sampleEvery {
						samplesMu.Lock()
						if len(samples) < 4096 {
							samples = append(samples, toSample(s, dg, sp, sigs, useEd))
						}
						samplesMu.Unlock()
					}
				}
			}
			total.Add(local % 64)
		}(mine, int64(w)+time.Now().UnixNano())
	}

	start := time.Now()
	ticker := time.NewTicker(time.Second)
	var perSecond []uint64
	var last uint64
	for range ticker.C {
		cur := total.Load()
		perSecond = append(perSecond, cur-last)
		last = cur
		fmt.Fprintf(os.Stderr, "\r%4ds  %12d effective tx/s", len(perSecond), perSecond[len(perSecond)-1])
		if time.Since(start) >= *dur {
			break
		}
	}
	ticker.Stop()
	stop.Store(true)
	wg.Wait()
	elapsed := time.Since(start)
	fmt.Fprintln(os.Stderr)
	if failures.Load() != 0 {
		fmt.Fprintf(os.Stderr, "signature verification failures: %d\n", failures.Load())
		os.Exit(1)
	}

	var peak uint64
	var sustainedSum uint64
	counted := 0
	for i, c := range perSecond {
		if c > peak {
			peak = c
		}
		if i >= *warmup {
			sustainedSum += c
			counted++
		}
	}
	rep := report{
		Definition: "A SphereState with a new version, signed by every participant and verified by every " +
			"other participant (Lightsphere HIP, Throughput accounting).",
		KeyType: *keyType, Spheres: *nSpheres, ParticipantsEach: *nParties, Workers: *workers,
		DurationSeconds: elapsed.Seconds(), WarmupSeconds: *warmup, EffectiveTxTotal: total.Load(),
		PeakTPS: peak, PerSecond: perSecond, ChainID: *chainID, AnchorContract: *anchorHex,
		SettlementTxIDs: []string{},
		SettlementNote: "Offline run: no spheres were opened or settled on an anchor ledger. A conforming " +
			"public report must list the anchor-ledger transaction IDs of every open and settlement.",
		StartedAt: start.UTC(),
		Hardware:  hardware{CPU: cpuModel(), Cores: runtime.NumCPU(), OS: runtime.GOOS, Arch: runtime.GOARCH, GoVer: runtime.Version()},
	}
	if counted > 0 {
		rep.SustainedTPS = float64(sustainedSum) / float64(counted)
		rep.SustainedWindowOK = counted >= 60
	}
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	rng.Shuffle(len(samples), func(i, j int) { samples[i], samples[j] = samples[j], samples[i] })
	if len(samples) > *nSamples {
		samples = samples[:*nSamples]
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i].SphereID < samples[j].SphereID })
	rep.Samples = samples

	b, _ := json.MarshalIndent(rep, "", "  ")
	if err := os.WriteFile(*out, append(b, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("keys=%s spheres=%d parties=%d workers=%d cpu=%q\n", *keyType, *nSpheres, *nParties, *workers, rep.Hardware.CPU)
	fmt.Printf("peak %d tx/s, sustained %.0f tx/s over %d s (conforming window: %v), total %d\n",
		peak, rep.SustainedTPS, counted, rep.SustainedWindowOK, rep.EffectiveTxTotal)
	fmt.Println("report:", *out)
}

func toSample(s *state.SphereState, dg [32]byte, sp *sphere, sigs [][]byte, useEd bool) sample {
	smp := sample{SphereID: hx(s.SphereID[:]), Version: s.Version, AppDataHash: hx(s.AppDataHash[:]), IsFinal: s.IsFinal, Digest: hx(dg[:])}
	for _, b := range s.Balances {
		smp.Balances = append(smp.Balances, b.String())
	}
	for j := range sp.parties {
		if useEd {
			smp.Signers = append(smp.Signers, hx(sp.parties[j].edPub))
		} else {
			smp.Signers = append(smp.Signers, sp.parties[j].addr.Hex())
		}
		smp.Signatures = append(smp.Signatures, hx(sigs[j]))
	}
	return smp
}
