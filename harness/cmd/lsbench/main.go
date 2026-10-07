// Command lsbench measures signed-mode Lightsphere throughput as the Lightsphere HIP defines it.
//
// One effective transaction is a SphereState with a new version that every participant has signed and every
// other participant has verified, with the secp256k1 signing keys the anchor contract checks. Each worker
// goroutine owns a set of spheres and runs them in a loop; nothing is counted until every signature on a state
// has been verified by every other participant.
//
// Rates are measured against the wall clock: each one-second sample divides the transactions completed since
// the previous sample by the real time elapsed, and the sustained rate is the total completed between the end
// of the warm-up and the end of the run, divided by that interval. Samples of fully signed states are drawn
// uniformly from the whole run (reservoir sampling), and the report includes each sphere's parameters so a
// verifier can recompute its sphere ID.
package main

import (
	"crypto/ecdsa"
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

	"github.com/ColdAI-org/lightsphere/harness/state"
)

type party struct {
	key  *ecdsa.PrivateKey
	pub  []byte
	addr common.Address
}

type sphere struct {
	params  *state.SphereParams
	state   state.SphereState
	parties []party
}

// Params is the JSON form of state.SphereParams.
type Params struct {
	Participants    []string `json:"participants"`
	Signers         []string `json:"signers"`
	Assets          []string `json:"assets"`
	InitialDeposits []string `json:"initialDeposits"`
	ChallengePeriod uint64   `json:"challengePeriod"`
	FundingDeadline uint64   `json:"fundingDeadline"`
	Salt            string   `json:"salt"`
}

type sample struct {
	Params      Params   `json:"params"`
	SphereID    string   `json:"sphereId"`
	Version     uint64   `json:"version"`
	Balances    []string `json:"balances"`
	AppDataHash string   `json:"appDataHash"`
	IsFinal     bool     `json:"isFinal"`
	Digest      string   `json:"digest"`
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
	PeakTPS           float64   `json:"peakTps"`
	SustainedTPS      float64   `json:"sustainedTps"`
	SustainedSeconds  float64   `json:"sustainedSeconds"`
	SustainedWindowOK bool      `json:"sustainedWindowAtLeast60s"`
	PerSecond         []float64 `json:"perSecond"`
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

func paramsJSON(p *state.SphereParams) Params {
	j := Params{ChallengePeriod: p.ChallengePeriod, FundingDeadline: p.FundingDeadline, Salt: hx(p.Salt[:])}
	for i := range p.Participants {
		j.Participants = append(j.Participants, p.Participants[i].Hex())
		j.Signers = append(j.Signers, p.Signers[i].Hex())
	}
	for _, a := range p.Assets {
		j.Assets = append(j.Assets, a.Hex())
	}
	for _, d := range p.InitialDeposits {
		j.InitialDeposits = append(j.InitialDeposits, d.String())
	}
	return j
}

// reservoir keeps a uniform random sample of size k from a stream (Algorithm R).
type reservoir struct {
	k     int
	seen  uint64
	items []sample
	rng   *rand.Rand
}

func (r *reservoir) offer(build func() sample) {
	r.seen++
	if len(r.items) < r.k {
		r.items = append(r.items, build())
		return
	}
	if j := r.rng.Uint64() % r.seen; j < uint64(r.k) {
		r.items[j] = build()
	}
}

func main() {
	nSpheres := flag.Int("spheres", 1024, "number of concurrent spheres")
	nParties := flag.Int("parties", 2, "participants per sphere (2..16)")
	workers := flag.Int("workers", runtime.NumCPU(), "worker goroutines")
	dur := flag.Duration("duration", 70*time.Second, "measured duration (warm-up plus at least 60 s for a conforming report)")
	warmup := flag.Int("warmup", 5, "seconds excluded from the sustained rate")
	chainID := flag.Uint64("chain", 296, "anchor ledger EVM chain id")
	anchorHex := flag.String("anchor", "0x00000000000000000000000000000000004c5350", "anchor contract address")
	nSamples := flag.Int("samples", 32, "fully signed states to include in the report")
	out := flag.String("out", "report.json", "report path")
	flag.Parse()
	if *nParties < 2 || *nParties > 16 {
		fmt.Fprintln(os.Stderr, "parties must be 2..16")
		os.Exit(2)
	}

	dom := state.NewDomain(*chainID, common.HexToAddress(*anchorHex))
	spheres := make([]*sphere, *nSpheres)
	for i := range spheres {
		p := &state.SphereParams{Assets: []common.Address{{}}, ChallengePeriod: 3600, FundingDeadline: 4102444800}
		sp := &sphere{params: p}
		for j := 0; j < *nParties; j++ {
			k, err := crypto.GenerateKey()
			if err != nil {
				panic(err)
			}
			pt := party{key: k, pub: crypto.CompressPubkey(&k.PublicKey), addr: crypto.PubkeyToAddress(k.PublicKey)}
			sp.parties = append(sp.parties, pt)
			p.Participants = append(p.Participants, pt.addr)
			p.Signers = append(p.Signers, pt.addr)
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
	reservoirs := make([]*reservoir, *workers)

	var wg sync.WaitGroup
	for w := 0; w < *workers; w++ {
		var mine []*sphere
		for i := w; i < len(spheres); i += *workers {
			mine = append(mine, spheres[i])
		}
		res := &reservoir{k: *nSamples, rng: rand.New(rand.NewSource(int64(w) + time.Now().UnixNano()))}
		reservoirs[w] = res
		if len(mine) == 0 {
			continue
		}
		wg.Add(1)
		go func(mine []*sphere, res *reservoir) {
			defer wg.Done()
			rng := res.rng
			one := big.NewInt(1)
			sigs := make([][]byte, *nParties)
			for !stop.Load() {
				for _, sp := range mine {
					s := &sp.state
					from := rng.Intn(*nParties)
					to := (from + 1 + rng.Intn(*nParties-1)) % *nParties
					if state.Transfer(s.Balances, 1, 0, from, to, one) != nil {
						_ = state.Transfer(s.Balances, 1, 0, to, from, one) // the other way round always succeeds
					}
					s.Version++
					s.AppDataHash[0], s.AppDataHash[1] = byte(s.Version), byte(s.Version>>8)
					dg := dom.Digest(s)
					// Every participant signs.
					for j := range sp.parties {
						sig, err := state.SignECDSA(sp.parties[j].key, dg)
						if err != nil {
							failures.Add(1)
						}
						sigs[j] = sig
					}
					// Every participant verifies every other participant's signature before it counts.
					ok := true
					for v := range sp.parties {
						for j := range sp.parties {
							if j != v {
								ok = ok && state.VerifyECDSA(sp.parties[j].pub, dg, sigs[j])
							}
						}
					}
					if !ok {
						failures.Add(1)
						continue
					}
					total.Add(1)
					res.offer(func() sample { return toSample(sp, dg, sigs) })
				}
			}
		}(mine, res)
	}

	type tick struct {
		at    time.Time
		count uint64
	}
	start := time.Now()
	ticks := []tick{{start, 0}}
	var perSecond []float64
	var peak float64
	ticker := time.NewTicker(time.Second)
	for now := range ticker.C {
		cur := total.Load()
		prev := ticks[len(ticks)-1]
		rate := float64(cur-prev.count) / now.Sub(prev.at).Seconds()
		ticks = append(ticks, tick{now, cur})
		perSecond = append(perSecond, rate)
		if len(perSecond) > *warmup && rate > peak {
			peak = rate
		}
		fmt.Fprintf(os.Stderr, "\r%4ds  %12.0f effective tx/s", len(perSecond), rate)
		if now.Sub(start) >= *dur {
			break
		}
	}
	ticker.Stop()
	stop.Store(true)
	wg.Wait()
	fmt.Fprintln(os.Stderr)
	if failures.Load() != 0 {
		fmt.Fprintf(os.Stderr, "signature failures: %d\n", failures.Load())
		os.Exit(1)
	}

	rep := report{
		Definition: "A SphereState with a new version, signed by every participant's secp256k1 signing key and verified " +
			"by every other participant (Lightsphere HIP, Throughput accounting).",
		KeyType: "secp256k1", Spheres: *nSpheres, ParticipantsEach: *nParties, Workers: *workers,
		WarmupSeconds: *warmup, PeakTPS: peak, PerSecond: perSecond, ChainID: *chainID, AnchorContract: *anchorHex,
		SettlementTxIDs: []string{},
		SettlementNote: "Offline run: no spheres were opened or settled on an anchor ledger. A conforming public " +
			"report must list the anchor-ledger transaction IDs of every open and settlement.",
		StartedAt: start.UTC(),
		Hardware:  hardware{CPU: cpuModel(), Cores: runtime.NumCPU(), OS: runtime.GOOS, Arch: runtime.GOARCH, GoVer: runtime.Version()},
	}
	last := ticks[len(ticks)-1]
	rep.DurationSeconds = last.at.Sub(start).Seconds()
	rep.EffectiveTxTotal = last.count // transactions finished after the last tick are not counted
	if len(ticks) > *warmup+1 {
		w := ticks[*warmup]
		rep.SustainedSeconds = last.at.Sub(w.at).Seconds()
		rep.SustainedTPS = float64(last.count-w.count) / rep.SustainedSeconds
		rep.SustainedWindowOK = rep.SustainedSeconds >= 60
	}
	rep.Samples = mergeReservoirs(reservoirs, *nSamples)

	b, _ := json.MarshalIndent(rep, "", "  ")
	if err := os.WriteFile(*out, append(b, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("keys=secp256k1 spheres=%d parties=%d workers=%d cpu=%q\n", *nSpheres, *nParties, *workers, rep.Hardware.CPU)
	fmt.Printf("peak %.0f tx/s, sustained %.0f tx/s over %.1f s (conforming window: %v), total %d\n",
		rep.PeakTPS, rep.SustainedTPS, rep.SustainedSeconds, rep.SustainedWindowOK, rep.EffectiveTxTotal)
	fmt.Println("report:", *out)
}

// mergeReservoirs draws n samples from the per-worker reservoirs, choosing each worker in proportion to how many
// states it produced, so the result is uniform over the whole run.
func mergeReservoirs(rs []*reservoir, n int) []sample {
	pick := rand.New(rand.NewSource(time.Now().UnixNano()))
	pools := make([][]sample, len(rs))
	weights := make([]uint64, len(rs))
	var total uint64
	for i, r := range rs {
		pools[i] = append([]sample(nil), r.items...)
		weights[i] = r.seen
		total += r.seen
	}
	var out []sample
	for len(out) < n && total > 0 {
		x := pick.Uint64() % total
		i := 0
		for x >= weights[i] {
			x -= weights[i]
			i++
		}
		if len(pools[i]) == 0 {
			total -= weights[i]
			weights[i] = 0
			continue
		}
		j := pick.Intn(len(pools[i]))
		out = append(out, pools[i][j])
		pools[i] = append(pools[i][:j], pools[i][j+1:]...)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SphereID < out[j].SphereID })
	return out
}

func toSample(sp *sphere, dg [32]byte, sigs [][]byte) sample {
	s := &sp.state
	smp := sample{Params: paramsJSON(sp.params), SphereID: hx(s.SphereID[:]), Version: s.Version,
		AppDataHash: hx(s.AppDataHash[:]), IsFinal: s.IsFinal, Digest: hx(dg[:])}
	for _, b := range s.Balances {
		smp.Balances = append(smp.Balances, b.String())
	}
	for j := range sp.parties {
		smp.Signatures = append(smp.Signatures, hx(sigs[j]))
	}
	return smp
}
