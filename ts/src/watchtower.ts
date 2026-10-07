// Reference watchtower (Lightsphere HIP, "Security Implications"). It holds the newest fully signed state for
// each sphere it guards and submits it with checkpoint() whenever the anchor records an older version, so an
// offline participant cannot lose to a stale close.
import type { Address, Hex, PublicClient, WalletClient, Account, Chain, Transport } from "viem";
import { anchorAbi } from "./anchorAbi.ts";
import type { SphereState } from "./state.ts";

export interface SignedState {
  state: SphereState;
  signatures: Hex[];
}

const STATUS_OPEN = 2;
const STATUS_CLOSING = 3;

export class Watchtower {
  readonly #latest = new Map<Hex, SignedState>();
  readonly #publicClient: PublicClient;
  readonly #walletClient: WalletClient<Transport, Chain, Account>;
  readonly #anchor: Address;
  #unwatch?: () => void;

  constructor(opts: {
    publicClient: PublicClient;
    walletClient: WalletClient<Transport, Chain, Account>;
    anchor: Address;
  }) {
    this.#publicClient = opts.publicClient;
    this.#walletClient = opts.walletClient;
    this.#anchor = opts.anchor;
  }

  /** Called by a participant's wallet after every fully signed update. Only newer versions are kept. */
  guard(signed: SignedState): void {
    const cur = this.#latest.get(signed.state.sphereId);
    if (!cur || signed.state.version > cur.state.version) this.#latest.set(signed.state.sphereId, signed);
  }

  /** Compares the anchor with the stored state and submits ours if it is newer. Returns the tx hash, if any. */
  async check(sphereId: Hex): Promise<Hex | undefined> {
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
    const hash = await this.#walletClient.writeContract({
      address: this.#anchor,
      abi: anchorAbi,
      functionName: "checkpoint",
      args: [ours.state, ours.signatures],
    });
    await this.#publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Reacts to every CloseStarted on the anchor. `onSubmit` sees each correction this tower makes. */
  start(onSubmit?: (sphereId: Hex, tx: Hex) => void, pollingInterval = 1_000): void {
    this.#unwatch = this.#publicClient.watchContractEvent({
      address: this.#anchor,
      abi: anchorAbi,
      eventName: "CloseStarted",
      pollingInterval,
      onLogs: async (logs) => {
        for (const log of logs) {
          const sid = log.args.sphereId;
          if (!sid) continue;
          const tx = await this.check(sid);
          if (tx) onSubmit?.(sid, tx);
        }
      },
    });
  }

  stop(): void {
    this.#unwatch?.();
  }
}
