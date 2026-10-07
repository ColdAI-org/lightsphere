import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import type { Address, Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sphereId, stateDigest, signState, verifyEcdsaSignatures, conserves, type SphereState } from "../src/state.ts";

const v = JSON.parse(readFileSync(new URL("../../contracts/test/vectors/signed-v1.json", import.meta.url), "utf8"));
const anchor = v.verifyingContract as Address;

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

test("signatures are byte-identical to the Go harness (RFC 6979) and verify", async () => {
  const accounts = (v.privateKeys as Hex[]).map((k) => privateKeyToAccount(k));
  assert.deepEqual(
    accounts.map((a) => a.address),
    v.participants,
  );
  for (const { s, sigs } of states) {
    for (let i = 0; i < accounts.length; i++) {
      assert.equal(await signState(accounts[i], v.chainId, anchor, s), sigs[i]);
    }
    assert.ok(await verifyEcdsaSignatures(v.chainId, anchor, s, v.participants, sigs));
    assert.ok(conserves(s, v.initialDeposits.map(BigInt), v.assets.length));
  }
});

test("a signature does not verify on another network or anchor", async () => {
  const { s, sigs } = states[0];
  assert.equal(await verifyEcdsaSignatures(295, anchor, s, v.participants, sigs), false);
  assert.equal(
    await verifyEcdsaSignatures(v.chainId, "0x00000000000000000000000000000000004c5351", s, v.participants, sigs),
    false,
  );
});
