// Publishes the riskguard package to testnet and records packageId + AdminCap id.
// Precondition: `sui client active-env` is testnet and `sui move build` passes.
// Uses the CLI to build (so the bundled framework aligns), then publishes via the SDK
// with the funded env keypair.
import { Transaction } from "@mysten/sui/transactions";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { client, keypairFromEnv, findPublishedPackage, findCreated, writeDeployed } from "./sui.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const MOVE_PKG = join(HERE, "..", "..", "move", "riskguard");

async function main() {
  const kp = keypairFromEnv();
  const sender = kp.getPublicKey().toSuiAddress();
  console.log("deployer:", sender);

  // Build with the CLI → emits base64 modules + dependency ids. --dump-bytecode-as-base64
  // keeps framework alignment in the CLI's hands (spec §9 protocol-alignment blocker).
  const out = execFileSync(
    "sui",
    ["move", "build", "--dump-bytecode-as-base64", "--path", MOVE_PKG],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  const { modules, dependencies } = JSON.parse(out) as {
    modules: string[];
    dependencies: string[];
  };

  const tx = new Transaction();
  const [upgradeCap] = tx.publish({ modules, dependencies });
  tx.transferObjects([upgradeCap], sender);

  const res = await client.signAndExecuteTransaction({
    signer: kp,
    transaction: tx,
    options: { showObjectChanges: true, showEffects: true },
  });
  if (res.effects?.status.status !== "success") {
    throw new Error(`publish failed: ${JSON.stringify(res.effects?.status)}`);
  }

  const packageId = findPublishedPackage(res.objectChanges);
  const adminCapId = findCreated(res.objectChanges, "::caps::AdminCap");
  const upgradeCapId = findCreated(res.objectChanges, "::package::UpgradeCap");
  const saved = writeDeployed({ packageId, adminCapId, upgradeCapId });
  console.log("published:", { packageId, adminCapId, upgradeCapId });
  console.log("wrote ts/.deployed.json:", saved);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
