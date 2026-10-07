// End to end on a local anvil chain: a participant starts a close on a stale state, and the watchtower, guarding
// the newer state, corrects it inside the challenge window. Also: the tower ignores forged states, survives
// reverts, and catches a close that happened while it was offline (persistence plus backfill).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Address, type Hex, createPublicClient, createWalletClient, http, keccak256, toHex, parseEventLogs } from "viem";
import { foundry } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { anchorAbi } from "../src/anchorAbi.ts";
import { Watchtower, FileStore } from "../src/watchtower.ts";
import { HBAR, signState, signJoin, type SphereState } from "../src/state.ts";

const PORT = 18545 + Math.floor(Math.random() * 1000);
const RPC = `http://127.0.0.1:${PORT}`;
// anvil's well-known development keys
const KEYS: Hex[] = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
];
const [alice, bob, tower] = KEYS.map((k) => privateKeyToAccount(k));
const artifact = (path: string) =>
  JSON.parse(readFileSync(new URL(`../../contracts/out/${path}`, import.meta.url), "utf8"));

let anvil: ChildProcess;
let anchor: Address;
let chainId: number;
const pub = createPublicClient({ chain: foundry, transport: http(RPC) });
const wallet = (account: typeof alice) => createWalletClient({ account, chain: foundry, transport: http(RPC) });
const rpc = pub.extend((c) => ({
  setCode: (address: Address, bytecode: Hex) => c.request({ method: "anvil_setCode" as any, params: [address, bytecode] as any }),
  increaseTime: (s: number) => c.request({ method: "evm_increaseTime" as any, params: [s] as any }),
  mine: () => c.request({ method: "evm_mine" as any, params: [] as any }),
}));
const deposit = 10n ** 18n;

before(async () => {
  anvil = spawn("anvil", ["--port", String(PORT), "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      await pub.getChainId();
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  chainId = await pub.getChainId();
  // The HTS system contract, as on a Hiero network.
  await rpc.setCode("0x0000000000000000000000000000000000000167", artifact("Mocks.sol/MockHTS.json").deployedBytecode.object);
  const hash = await wallet(alice).deployContract({
    abi: anchorAbi,
    bytecode: artifact("LightsphereAnchor.sol/LightsphereAnchor.json").bytecode.object,
    args: ["0x000000000000000000000000000000000000c1a9", 3600n],
  });
  anchor = (await pub.waitForTransactionReceipt({ hash })).contractAddress!;
});

after(() => {
  anvil?.kill();
});

async function openAndFund(salt: string): Promise<Hex> {
  const block = await pub.getBlock();
  const params = {
    mode: 0,
    participants: [alice.address, bob.address],
    signers: [alice.address, bob.address],
    assets: [HBAR],
    initialDeposits: [deposit, deposit],
    challengePeriod: 3600n,
    fundingDeadline: block.timestamp + 86400n,
    networkConfig: "0x" as Hex,
    salt: keccak256(toHex(salt)),
  };
  const receipt = await pub.waitForTransactionReceipt({
    hash: await wallet(alice).writeContract({ address: anchor, abi: anchorAbi, functionName: "open", args: [params] }),
  });
  const [opened] = parseEventLogs({ abi: anchorAbi, logs: receipt.logs, eventName: "SphereOpened" });
  const sid = opened.args.sphereId;
  for (const who of [alice, bob]) {
    const joinSig = await signJoin(who, chainId, anchor, sid, who.address);
    await pub.waitForTransactionReceipt({
      hash: await wallet(who).writeContract({
        address: anchor,
        abi: anchorAbi,
        functionName: "fund",
        args: [sid, joinSig],
        value: deposit,
      }),
    });
  }
  return sid;
}

const mk = (sid: Hex, version: bigint, aliceBal: bigint): SphereState => ({
  sphereId: sid,
  version,
  balances: [aliceBal, 2n * deposit - aliceBal],
  appDataHash: keccak256(toHex(`v${version}`)),
  isFinal: false,
});
const signBoth = (s: SphereState) => Promise.all([alice, bob].map((a) => signState(a, chainId, anchor, s)));

async function startStaleClose(sid: Hex) {
  const stale = mk(sid, 3n, deposit + deposit / 2n); // Alice up 0.5
  const receipt = await pub.waitForTransactionReceipt({
    hash: await wallet(alice).writeContract({
      address: anchor,
      abi: anchorAbi,
      functionName: "startClose",
      args: [sid, stale, await signBoth(stale)],
    }),
  });
  return receipt.blockNumber;
}

async function finalizeAndCheck(sid: Hex, expectedBob: bigint) {
  const before = await pub.readContract({ address: anchor, abi: anchorAbi, functionName: "claimable", args: [bob.address, HBAR] });
  await rpc.increaseTime(3601);
  await rpc.mine();
  await pub.waitForTransactionReceipt({
    hash: await wallet(bob).writeContract({ address: anchor, abi: anchorAbi, functionName: "finalizeClose", args: [sid] }),
  });
  const owed = await pub.readContract({ address: anchor, abi: anchorAbi, functionName: "claimable", args: [bob.address, HBAR] });
  assert.equal(owed - before, expectedBob);
}

test("watchtower replaces a stale close with the newest signed state, and ignores forged states", async () => {
  const sid = await openAndFund("live");
  const latest = mk(sid, 250n, deposit / 4n); // Bob up 0.75 after many more updates
  const watchtower = new Watchtower({ publicClient: pub, walletClient: wallet(tower), anchor });
  assert.equal(await watchtower.guard({ state: latest, signatures: await signBoth(latest) }), true);

  // A forged state with a huge version but junk signatures must not displace the real one.
  const forged = mk(sid, 1n << 60n, 0n);
  assert.equal(await watchtower.guard({ state: forged, signatures: ["0x00", "0x00"] }), false);
  const wrongSigner = await Promise.all([alice, tower].map((a) => signState(a, chainId, anchor, forged)));
  assert.equal(await watchtower.guard({ state: forged, signatures: wrongSigner }), false);

  const errors: unknown[] = [];
  const corrected = new Promise<Hex>((resolve) =>
    watchtower.start({ onSubmit: (_, tx) => resolve(tx), onError: (e) => errors.push(e), pollingInterval: 200, sweepInterval: 0 }),
  );
  await startStaleClose(sid);
  await corrected;
  watchtower.stop();
  const [version] = await pub.readContract({ address: anchor, abi: anchorAbi, functionName: "latestState", args: [sid] });
  assert.equal(version, 250n);
  assert.deepEqual(errors, []);
  // Checking again is a no-op, not a revert.
  assert.equal(await watchtower.check(sid), undefined);
  await finalizeAndCheck(sid, 2n * deposit - deposit / 4n);
});

test("a restarted watchtower catches a close that happened while it was offline", async () => {
  const sid = await openAndFund("offline");
  const storePath = join(mkdtempSync(join(tmpdir(), "lightsphere-")), "tower.json");
  const latest = mk(sid, 900n, deposit / 2n);
  const first = new Watchtower({ publicClient: pub, walletClient: wallet(tower), anchor, store: new FileStore(storePath) });
  assert.equal(await first.guard({ state: latest, signatures: await signBoth(latest) }), true);
  const lastSeen = await pub.getBlockNumber();
  // The tower goes offline here; Alice starts a stale close.
  await startStaleClose(sid);

  const second = new Watchtower({ publicClient: pub, walletClient: wallet(tower), anchor, store: new FileStore(storePath) });
  const corrected = new Promise<Hex>((resolve) =>
    second.start({ fromBlock: lastSeen, onSubmit: (_, tx) => resolve(tx), pollingInterval: 200, sweepInterval: 0 }),
  );
  await corrected;
  second.stop();
  await finalizeAndCheck(sid, 2n * deposit - deposit / 2n);
});
