import { SuiClient, getFullnodeUrl, type SuiObjectChange } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

export const client = new SuiClient({ url: getFullnodeUrl("testnet") });

export function keypairFromEnv(): Ed25519Keypair {
  const key = process.env.SUI_TESTNET_KEY;
  if (!key) throw new Error("SUI_TESTNET_KEY not set (see ts/.env.example)");
  const { secretKey } = decodeSuiPrivateKey(key.trim());
  return Ed25519Keypair.fromSecretKey(secretKey);
}

const HERE = dirname(fileURLToPath(import.meta.url));
const DEPLOYED_PATH = join(HERE, "..", ".deployed.json");

export type Deployed = {
  packageId?: string;
  adminCapId?: string;
  oracleId?: string;
  policyId?: string;
  publisherCapId?: string;
  emergencyCapId?: string;
  overrideCapId?: string;
  upgradeCapId?: string;
  upgradeRegistryId?: string;
};

export function readDeployed(): Deployed {
  return existsSync(DEPLOYED_PATH)
    ? (JSON.parse(readFileSync(DEPLOYED_PATH, "utf8")) as Deployed)
    : {};
}

export function writeDeployed(patch: Deployed): Deployed {
  const merged = { ...readDeployed(), ...patch };
  writeFileSync(DEPLOYED_PATH, JSON.stringify(merged, null, 2) + "\n");
  return merged;
}

// Find the first created object whose objectType ends with `::<module>::<struct>`.
export function findCreated(
  changes: SuiObjectChange[] | null | undefined,
  suffix: string,
): string {
  const hit = (changes ?? []).find(
    (c): c is Extract<SuiObjectChange, { type: "created" }> =>
      c.type === "created" &&
      (c.objectType.endsWith(suffix) || c.objectType.includes(`${suffix}<`)),
  );
  if (!hit) throw new Error(`no created object matching ${suffix}`);
  return hit.objectId;
}

export function findPublishedPackage(changes: SuiObjectChange[] | null | undefined): string {
  const hit = (changes ?? []).find(
    (c): c is Extract<SuiObjectChange, { type: "published" }> => c.type === "published",
  );
  if (!hit) throw new Error("no published package in objectChanges");
  return hit.packageId;
}
