// Lightsphere signed-mode state encoding (Lightsphere HIP, "State encoding").
import {
  type Address,
  type Hex,
  encodeAbiParameters,
  hashTypedData,
  hexToBigInt,
  keccak256,
  recoverAddress,
  slice,
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
  /** Accounts that fund, start a close and receive payouts. */
  participants: Address[];
  /** One secp256k1 signing address per participant. States are signed with these keys. */
  signers: Address[];
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

export const joinSphereTypes = {
  JoinSphere: [
    { name: "sphereId", type: "bytes32" },
    { name: "participant", type: "address" },
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

/** The JoinSphere signature a participant's signing key gives when the participant funds the sphere. */
export async function signJoin(
  signingKey: LocalAccount,
  chainId: number | bigint,
  anchor: Address,
  sphereId: Hex,
  participant: Address,
): Promise<Hex> {
  return signingKey.signTypedData({
    domain: lightsphereDomain(chainId, anchor),
    types: joinSphereTypes,
    primaryType: "JoinSphere",
    message: { sphereId, participant },
  });
}

const SECP256K1_HALF_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n;

/** True if the anchor would accept this signature from `signer` over `hash`: 65 bytes, v in {0,1,27,28}, low s. */
export async function isValidSignature(hash: Hex, signature: Hex, signer: Address): Promise<boolean> {
  if (!/^0x[0-9a-fA-F]{130}$/.test(signature)) return false;
  const v = Number(hexToBigInt(slice(signature, 64, 65)));
  if (![0, 1, 27, 28].includes(v)) return false;
  if (hexToBigInt(slice(signature, 32, 64)) > SECP256K1_HALF_N) return false;
  try {
    const recovered = await recoverAddress({ hash, signature });
    return recovered.toLowerCase() === signer.toLowerCase();
  } catch {
    return false;
  }
}

/** Checks one signature per signer, in order, exactly as the anchor does. */
export async function verifyStateSignatures(
  chainId: number | bigint,
  anchor: Address,
  state: SphereState,
  signers: Address[],
  signatures: Hex[],
): Promise<boolean> {
  if (signatures.length !== signers.length || signers.length === 0) return false;
  const hash = stateDigest(chainId, anchor, state);
  for (let i = 0; i < signers.length; i++) {
    if (!(await isValidSignature(hash, signatures[i], signers[i]))) return false;
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
      { name: "signers", type: "address[]" },
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
