import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { type Address, type Hex, hashTypedData, hexToBigInt, slice, concat, numberToHex, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  sphereId,
  stateDigest,
  signState,
  signJoin,
  verifyStateSignatures,
  isValidSignature,
  conserves,
  lightsphereDomain,
  joinSphereTypes,
  type SphereState,
} from "../src/state.ts";

const v = JSON.parse(readFileSync(new URL("../../contracts/test/vectors/signed-v1.json", import.meta.url), "utf8"));
const anchor = v.verifyingContract as Address;
const accounts = (v.privateKeys as Hex[]).map((k) => privateKeyToAccount(k));

const states: { s: SphereState; digest: Hex; sigs: Hex[] }[] = v.states.map((j: any) => ({
  s: {
    sphereId: j.sphereId,
    version: BigInt(j.version),
    balances: j.balances.map(BigInt),
    appDataHash: j.appDataHash,
    isFinal: j.isFinal,
  },
  digest: j.digest,
  sigs: j.signatures,
}));

test("sphereId matches the Go harness and the contract", () => {
  const id = sphereId(v.chainId, anchor, {
    mode: 0,
    participants: v.participants,
    signers: v.signers,
    assets: v.assets,
    initialDeposits: v.initialDeposits.map(BigInt),
    challengePeriod: BigInt(v.challengePeriod),
    fundingDeadline: BigInt(v.fundingDeadline),
    networkConfig: "0x",
    salt: v.salt,
  });
  assert.equal(id, v.sphereId);
});

test("EIP-712 digests match", () => {
  for (const { s, digest } of states) assert.equal(stateDigest(v.chainId, anchor, s), digest);
});

test("state and join signatures are byte-identical to the Go harness (RFC 6979) and verify", async () => {
  assert.deepEqual(
    accounts.map((a) => a.address),
    v.signers,
  );
  for (const { s, sigs } of states) {
    for (let i = 0; i < accounts.length; i++) {
      assert.equal(await signState(accounts[i], v.chainId, anchor, s), sigs[i]);
    }
    assert.ok(await verifyStateSignatures(v.chainId, anchor, s, v.signers, sigs));
    assert.ok(conserves(s, v.initialDeposits.map(BigInt), v.assets.length));
  }
  for (let i = 0; i < accounts.length; i++) {
    assert.equal(await signJoin(accounts[i], v.chainId, anchor, v.sphereId, v.participants[i]), v.joinSignatures[i]);
  }
});

test("a signature does not verify on another network, anchor or signer order", async () => {
  const { s, sigs } = states[0];
  assert.equal(await verifyStateSignatures(295, anchor, s, v.signers, sigs), false);
  assert.equal(
    await verifyStateSignatures(v.chainId, "0x00000000000000000000000000000000004c5351", s, v.signers, sigs),
    false,
  );
  assert.equal(await verifyStateSignatures(v.chainId, anchor, s, [...v.signers].reverse(), sigs), false);
  assert.equal(await verifyStateSignatures(v.chainId, anchor, s, v.signers, [sigs[0]]), false);
  assert.equal(await verifyStateSignatures(v.chainId, anchor, s, [], []), false);
});

test("high-s and out-of-range v are rejected, as the anchor rejects them", async () => {
  const { s, sigs } = states[0];
  const hash = stateDigest(v.chainId, anchor, s);
  const n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
  const r = slice(sigs[1], 0, 32);
  const sv = hexToBigInt(slice(sigs[1], 32, 64));
  const vByte = Number(hexToBigInt(slice(sigs[1], 64, 65)));
  const highS = concat([r, numberToHex(n - sv, { size: 32 }), numberToHex(vByte === 27 ? 28 : 27, { size: 1 })]);
  assert.equal(await isValidSignature(hash, highS, v.signers[1]), false);
  const badV = concat([r, numberToHex(sv, { size: 32 }), numberToHex(vByte + 2, { size: 1 })]);
  assert.equal(await isValidSignature(hash, badV, v.signers[1]), false);
  const zeroOneV = concat([r, numberToHex(sv, { size: 32 }), numberToHex(vByte - 27, { size: 1 })]);
  assert.equal(await isValidSignature(hash, zeroOneV, v.signers[1]), true);
  assert.equal(await isValidSignature(hash, toHex("short"), v.signers[1]), false);
});

test("join digest uses the same domain", () => {
  const d = hashTypedData({
    domain: lightsphereDomain(v.chainId, anchor),
    types: joinSphereTypes,
    primaryType: "JoinSphere",
    message: { sphereId: v.sphereId, participant: v.participants[0] },
  });
  assert.match(d, /^0x[0-9a-f]{64}$/);
});
