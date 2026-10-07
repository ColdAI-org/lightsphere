// Reference watchtower (Lightsphere HIP, "Security Implications"). It holds the newest fully signed state for
// each sphere it guards and submits it with checkpoint() whenever the anchor records an older version, so an
// offline participant cannot lose to a stale close.
//
// Design rules, each from a review finding:
// - guard() verifies every signature against the sphere's signing keys on the anchor before storing anything,
//   so nobody can displace a real state with a higher-versioned junk one.
// - Nothing thrown while handling events escapes: errors go to onError, and one bad log never stops the rest.
// - State survives restarts (pluggable store), start() can backfill from a block, and a periodic sweep re-checks
//   every guarded sphere, so a CloseStarted event missed while offline is still caught inside the window.
import { readFile, writeFile, rename } from "node:fs/promises";
import type { Account, Address, Chain, Hex, PublicClient, Transport, WalletClient } from "viem";
import { anchorAbi } from "./anchorAbi.ts";
import { verifyStateSignatures, type SphereState } from "./state.ts";

export interface SignedState {
  state: SphereState;
  signatures: Hex[];
}

/** Where a watchtower keeps the states it guards. */
export interface WatchtowerStore {
  load(): Promise<SignedState[]>;
  save(states: SignedState[]): Promise<void>;
}

export class MemoryStore implements WatchtowerStore {
  #states: SignedState[] = [];
  async load() {
    return this.#states;
  }
  async save(states: SignedState[]) {
    this.#states = states;
  }
}

/** JSON file store. Writes go to a temporary file first and are renamed into place. */
export class FileStore implements WatchtowerStore {
  readonly path: string;
  constructor(path: string) {
    this.path = path;
  }
  async load(): Promise<SignedState[]> {
    let raw: string;
    try {
      raw = await readFile(this.path, "utf8");
    } catch {
      return [];
    }
    return JSON.parse(raw, (_k, v) => (typeof v === "string" && /^\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v));
  }
  async save(states: SignedState[]): Promise<void> {
    const body = JSON.stringify(states, (_k, v) => (typeof v === "bigint" ? `${v}n` : v), 2);
    await writeFile(`${this.path}.tmp`, body);
    await rename(`${this.path}.tmp`, this.path);
  }
}

const STATUS_OPEN = 2;
const STATUS_CLOSING = 3;
const UINT64_MAX = (1n << 64n) - 1n;

export interface StartOptions {
  /** Called after each successful correction. */
  onSubmit?: (sphereId: Hex, tx: Hex) => void;
  /** Called with every error. The tower keeps running. */
  onError?: (error: unknown) => void;
  /** Replay CloseStarted events from this block (for example, the last block seen before a restart). */
  fromBlock?: bigint;
  /** Event polling interval in ms. */
  pollingInterval?: number;
  /** How often to re-check every guarded sphere, in ms. 0 disables the sweep. */
  sweepInterval?: number;
}

export class Watchtower {
  readonly #latest = new Map<Hex, SignedState>();
  readonly #publicClient: PublicClient;
  readonly #walletClient: WalletClient<Transport, Chain, Account>;
  readonly #anchor: Address;
  readonly #store: WatchtowerStore;
  #unwatch?: () => void;
  #sweep?: ReturnType<typeof setInterval>;
  #loaded = false;

  constructor(opts: {
    publicClient: PublicClient;
    walletClient: WalletClient<Transport, Chain, Account>;
    anchor: Address;
    store?: WatchtowerStore;
  }) {
    this.#publicClient = opts.publicClient;
    this.#walletClient = opts.walletClient;
    this.#anchor = opts.anchor;
    this.#store = opts.store ?? new MemoryStore();
  }

  async #load(): Promise<void> {
    if (this.#loaded) return;
    for (const s of await this.#store.load()) this.#latest.set(s.state.sphereId, s);
    this.#loaded = true;
  }

  /** Spheres this tower currently guards. */
  get guarded(): Hex[] {
    return [...this.#latest.keys()];
  }

  /**
   * Called by a participant's wallet after every fully signed update. Returns false, and stores nothing, unless
   * the state is newer than the one held and every signature checks out against the anchor's signing keys.
   */
  async guard(signed: SignedState): Promise<boolean> {
    await this.#load();
    const { state, signatures } = signed;
    if (state.version > UINT64_MAX || state.version < 0n) return false;
    const cur = this.#latest.get(state.sphereId);
    if (cur && state.version <= cur.state.version) return false;
    const [, signers] = await this.#publicClient.readContract({
      address: this.#anchor,
      abi: anchorAbi,
      functionName: "participantsOf",
      args: [state.sphereId],
    });
    if (signers.length === 0) return false;
    const chainId = await this.#publicClient.getChainId();
    if (!(await verifyStateSignatures(chainId, this.#anchor, state, [...signers], signatures))) return false;
    this.#latest.set(state.sphereId, signed);
    await this.#store.save([...this.#latest.values()]);
    return true;
  }

  /** Compares the anchor with the stored state and submits ours if it is newer. Returns the tx hash, if any. */
  async check(sphereId: Hex): Promise<Hex | undefined> {
    await this.#load();
    const ours = this.#latest.get(sphereId);
    if (!ours) return undefined;
    const [status, [version], endsAt, block] = await Promise.all([
      this.#publicClient.readContract({ address: this.#anchor, abi: anchorAbi, functionName: "status", args: [sphereId] }),
      this.#publicClient.readContract({ address: this.#anchor, abi: anchorAbi, functionName: "latestState", args: [sphereId] }),
      this.#publicClient.readContract({ address: this.#anchor, abi: anchorAbi, functionName: "challengeEndsAt", args: [sphereId] }),
      this.#publicClient.getBlock(),
    ]);
    if (status !== STATUS_OPEN && status !== STATUS_CLOSING) return undefined;
    if (status === STATUS_CLOSING && block.timestamp >= endsAt) return undefined;
    if (version >= ours.state.version) return undefined;
    // Simulate first: if someone else already submitted this version, or the window just closed, skip quietly.
    try {
      await this.#publicClient.simulateContract({
        account: this.#walletClient.account,
        address: this.#anchor,
        abi: anchorAbi,
        functionName: "checkpoint",
        args: [ours.state, ours.signatures],
      });
    } catch {
      return undefined;
    }
    const hash = await this.#walletClient.writeContract({
      address: this.#anchor,
      abi: anchorAbi,
      functionName: "checkpoint",
      args: [ours.state, ours.signatures],
    });
    await this.#publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Re-checks every guarded sphere. Errors go to onError; one failing sphere never stops the others. */
  async sweep(onSubmit?: StartOptions["onSubmit"], onError?: StartOptions["onError"]): Promise<void> {
    await this.#load();
    for (const sid of this.guarded) {
      try {
        const tx = await this.check(sid);
        if (tx) onSubmit?.(sid, tx);
      } catch (e) {
        onError?.(e);
      }
    }
  }

  /** Reacts to CloseStarted events, optionally replaying from `fromBlock`, and sweeps on a timer. */
  async start(opts: StartOptions = {}): Promise<void> {
    await this.#load();
    const { onSubmit, onError, fromBlock, pollingInterval = 1_000, sweepInterval = 60_000 } = opts;
    this.#unwatch = this.#publicClient.watchContractEvent({
      address: this.#anchor,
      abi: anchorAbi,
      eventName: "CloseStarted",
      fromBlock,
      pollingInterval,
      onError: (e) => onError?.(e),
      onLogs: async (logs) => {
        for (const log of logs) {
          const sid = log.args.sphereId;
          if (!sid) continue;
          try {
            const tx = await this.check(sid);
            if (tx) onSubmit?.(sid, tx);
          } catch (e) {
            onError?.(e);
          }
        }
      },
    });
    if (sweepInterval > 0) {
      this.#sweep = setInterval(() => void this.sweep(onSubmit, onError), sweepInterval);
      this.#sweep.unref?.();
    }
  }

  stop(): void {
    this.#unwatch?.();
    if (this.#sweep) clearInterval(this.#sweep);
  }
}
