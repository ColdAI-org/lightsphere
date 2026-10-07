// End to end on a local anvil chain: a participant starts a close on a stale state, and the watchtower,
// guarding the newer state, corrects it inside the challenge window.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  type Address,
  type Hex,
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toHex,
  parseEventLogs,
} from "viem";
import { foundry } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { anchorAbi } from "../src/anchorAbi.ts";
import { Watchtower } from "../src/watchtower.ts";
import { HBAR, signState, type SphereState } from "../src/state.ts";

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
const pub = createPublicClient({ chain: foundry, transport: http(RPC) });
const wallet = (account: typeof alice) => createWalletClient({ account, chain: foundry, transport: http(RPC) });

before(async () => {
  anvil = spawn("anvil", ["--port", String(PORT), "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      await pub.getChainId();
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("anvil did not start");
});

after(() => {
  anvil?.kill();
});

test("watchtower replaces a stale close with the newest signed state", async () => {
  const test = pub.extend((c) => ({
    setCode: (address: Address, bytecode: Hex) => c.request({ method: "anvil_setCode" as any, params: [address, bytecode] as any }),
    increaseTime: (s: number) => c.request({ method: "evm_increaseTime" as any, params: [s] as any }),
    mine: () => c.request({ method: "evm_mine" as any, params: [] as any }),
  }));
  // Hedera system contracts, as on a Hiero network.
  await test.setCode("0x0000000000000000000000000000000000000167", artifact("Mocks.sol/MockHTS.json").deployedBytecode.object);
  await test.setCode("0x000000000000000000000000000000000000016a", artifact("Mocks.sol/MockHAS.json").deployedBytecode.object);

  const deployer = wallet(alice);
  const deployHash = await deployer.deployContract({
    abi: anchorAbi,
    bytecode: artifact("LightsphereAnchor.sol/LightsphereAnchor.json").bytecode.object,
    args: ["0x000000000000000000000000000000000000c1a9", 3600n],
  });
  const anchor = (await pub.waitForTransactionReceipt({ hash: deployHash })).contractAddress!;
  const chainId = await pub.getChainId();

  const deposit = 10n ** 18n;
  const block = await pub.getBlock();
  const params = {
    mode: 0,
    participants: [alice.address, bob.address],
    assets: [HBAR],
    initialDeposits: [deposit, deposit],
    challengePeriod: 3600n,
    fundingDeadline: block.timestamp + 86400n,
    networkConfig: "0x" as Hex,
    salt: keccak256(toHex("e2e")),
  };
  const openReceipt = await pub.waitForTransactionReceipt({
    hash: await deployer.writeContract({ address: anchor, abi: anchorAbi, functionName: "open", args: [params] }),
  });
  const [opened] = parseEventLogs({ abi: anchorAbi, logs: openReceipt.logs, eventName: "SphereOpened" });
  const sid = opened.args.sphereId;
  for (const who of [alice, bob]) {
    await pub.waitForTransactionReceipt({
      hash: await wallet(who).writeContract({ address: anchor, abi: anchorAbi, functionName: "fund", args: [sid], value: deposit }),
    });
  }

  const mk = (version: bigint, aliceBal: bigint): SphereState => ({
    sphereId: sid,
    version,
    balances: [aliceBal, 2n * deposit - aliceBal],
    appDataHash: keccak256(toHex(`v${version}`)),
    isFinal: false,
  });
  const signBoth = (s: SphereState) => Promise.all([alice, bob].map((a) => signState(a, chainId, anchor, s)));
  const stale = mk(3n, deposit + deposit / 2n); // Alice up 0.5
  const latest = mk(250n, deposit / 4n); // Bob up 0.75 after many more updates

  const watchtower = new Watchtower({ publicClient: pub, walletClient: wallet(tower), anchor });
  watchtower.guard({ state: latest, signatures: await signBoth(latest) });
  const corrected = new Promise<Hex>((resolve) => watchtower.start((_, tx) => resolve(tx), 200));

  // Alice starts a close with the old state that favours her.
  await pub.waitForTransactionReceipt({
    hash: await wallet(alice).writeContract({
      address: anchor,
      abi: anchorAbi,
      functionName: "startClose",
      args: [sid, stale, await signBoth(stale)],
    }),
  });
  await corrected;
  watchtower.stop();
  const [version] = await pub.readContract({ address: anchor, abi: anchorAbi, functionName: "latestState", args: [sid] });
  assert.equal(version, 250n);

  await test.increaseTime(3601);
  await test.mine();
  await pub.waitForTransactionReceipt({
    hash: await wallet(bob).writeContract({ address: anchor, abi: anchorAbi, functionName: "finalizeClose", args: [sid] }),
  });
  const bobClaim = await pub.readContract({ address: anchor, abi: anchorAbi, functionName: "claimable", args: [bob.address, HBAR] });
  assert.equal(bobClaim, 2n * deposit - deposit / 4n);
});
