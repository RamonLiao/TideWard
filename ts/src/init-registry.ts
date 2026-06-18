// Wraps the deployer-held UpgradeCap into a shared UpgradeRegistry (one-shot)
// and records upgradeRegistryId into .deployed.json.
import { Transaction } from "@mysten/sui/transactions";
import { client, keypairFromEnv, readDeployed, writeDeployed, findCreated } from "./sui.js";
import { fq } from "./config.js";

async function main() {
  const kp = keypairFromEnv();
  const d = readDeployed();
  if (!d.packageId || !d.adminCapId || !d.upgradeCapId) {
    throw new Error("need packageId/adminCapId/upgradeCapId in .deployed.json");
  }
  const tx = new Transaction();
  tx.moveCall({
    target: fq(d.packageId, "upgrade_registry", "init_upgrade_registry"),
    arguments: [tx.object(d.upgradeCapId), tx.object(d.adminCapId)],
  });
  const res = await client.signAndExecuteTransaction({
    signer: kp, transaction: tx,
    options: { showObjectChanges: true, showEffects: true },
  });
  if (res.effects?.status.status !== "success") {
    throw new Error(`init-registry failed: ${JSON.stringify(res.effects?.status)}`);
  }
  const upgradeRegistryId = findCreated(res.objectChanges, "::upgrade_registry::UpgradeRegistry");
  const saved = writeDeployed({ upgradeRegistryId });
  console.log("wrote ts/.deployed.json:", saved);
}
main().catch((e) => { console.error(e); process.exit(1); });
