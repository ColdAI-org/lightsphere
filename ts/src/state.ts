// Lightsphere signed-mode state encoding (Lightsphere HIP, "State encoding").
import {
  type Address,
  type Hex,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
  recoverAddress,
} from "viem";
import type { LocalAccount } from "viem/accounts";

export const HBAR: Address = "0x0000000000000000000000000000000000000000";

/** EVM chain ids of the Hedera networks. Any Hiero network may use its own. */
export const HEDERA_CHAIN_IDS = { mainnet: 295, testnet: 296, previewnet: 297 } as const;

export interface SphereState {
  sphereId: Hex;
  version: bigint;
  /** Participant-major: index = participant * assets.length + asset. */
  balances: bigint[];
  appDataHash: Hex;
  isFinal: boolean;
}

export interface SphereParams {
  mode: number;
  participants: Address[];
  assets: Address[];
  initialDeposits: bigint[];
  challengePeriod: bigint;
  fundingDeadline: bigint;
  networkConfig: Hex;
  salt: Hex;
}

export const sphereStateTypes = {
  SphereState: [
    { name: "sphereId", type: "bytes32" },
    { name: "version", type: "uint64" },
    { name: "balances", type: "uint256[]" },
    { name: "appDataHash", type: "bytes32" },
    { name: "isFinal", type: "bool" },
  ],
} as const;

export function lightsphereDomain(chainId: number | bigint, anchor: Address) {
  return { name: "Lightsphere", version: "1", chainId: BigInt(chainId), verifyingContract: anchor } as const;
}

export function stateDigest(chainId: number | bigint, anchor: Address, state: SphereState): Hex {
  return hashTypedData({
    domain: lightsphereDomain(chainId, anchor),
    types: sphereStateTypes,
    primaryType: "SphereState",
    message: state,
  });
}

/** Signs a state as one participant. viem produces low-s, 65-byte r||s||v signatures. */
export async function signState(
  account: LocalAccount,
  chainId: number | bigint,
  anchor: Address,
  state: SphereState,
): Promise<Hex> {
  return account.signTypedData({
    domain: lightsphereDomain(chainId, anchor),
    types: sphereStateTypes,
    primaryType: "SphereState",
    message: state,
  });
}

/**
 * Checks ECDSA signatures from EVM-address participants, in participant order. ED25519 participants and
 * long-zero aliases are verified on-ledger by HIP-632 isAuthorizedRaw and are reported as unverified here.
 */
export async function verifyEcdsaSignatures(
  chainId: number | bigint,
  anchor: Address,
  state: SphereState,
  participants: Address[],
  signatures: Hex[],
): Promise<boolean> {
  if (signatures.length !== participants.length) return false;
  const hash = stateDigest(chainId, anchor, state);
  for (let i = 0; i < participants.length; i++) {
    if (signatures[i].length !== 132) return false;
    const signer = await recoverAddress({ hash, signature: signatures[i] });
    if (signer.toLowerCase() !== participants[i].toLowerCase()) return false;
  }
  return true;
}

const paramsAbi = [
  { type: "uint256" },
  { type: "address" },
  {
    type: "tuple",
    components: [
      { name: "mode", type: "uint8" },
      { name: "participants", type: "address[]" },
      { name: "assets", type: "address[]" },
      { name: "initialDeposits", type: "uint256[]" },
      { name: "challengePeriod", type: "uint64" },
      { name: "fundingDeadline", type: "uint64" },
      { name: "networkConfig", type: "bytes" },
      { name: "salt", type: "bytes32" },
    ],
  },
] as const;

/** sphereId = keccak256(abi.encode(chainId, anchor, params)). */
export function sphereId(chainId: number | bigint, anchor: Address, params: SphereParams): Hex {
  return keccak256(encodeAbiParameters(paramsAbi, [BigInt(chainId), anchor, params]));
}

/** Checks fund conservation the way the anchor does, before anyone signs. */
export function conserves(state: SphereState, initialDeposits: bigint[], nAssets: number): boolean {
  if (state.balances.length !== initialDeposits.length) return false;
  const nP = initialDeposits.length / nAssets;
  for (let a = 0; a < nAssets; a++) {
    let want = 0n;
    let got = 0n;
    for (let p = 0; p < nP; p++) {
      want += initialDeposits[p * nAssets + a];
      got += state.balances[p * nAssets + a];
    }
    if (want !== got) return false;
  }
  return true;
}
