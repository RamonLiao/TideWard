// Reads ts/.deployed.json (gitignored, source of truth for testnet ids)
// and writes app/.env.local for Vite. Run after every redeploy.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const d = JSON.parse(readFileSync(join(here, "../../ts/.deployed.json"), "utf8"));
const required = ["packageId", "oracleId", "policyId", "upgradeRegistryId"];
for (const k of required) if (!d[k]) throw new Error(`missing ${k} in ts/.deployed.json`);

const env = [
  `VITE_PKG=${d.packageId}`,
  `VITE_ORACLE_ID=${d.oracleId}`,
  `VITE_POLICY_ID=${d.policyId}`,
  `VITE_REGISTRY_ID=${d.upgradeRegistryId}`,
  `VITE_RPC_URL=https://fullnode.testnet.sui.io:443`,
].join("\n") + "\n";
writeFileSync(join(here, "../.env.local"), env);
console.log("wrote app/.env.local");
