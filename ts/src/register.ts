// Calls register_market<0x2::sui::SUI> with the e2e config and records the shared
// RiskOracle / RiskPolicy ids and the publisher cap id into .deployed.json.
import { Transaction } from "@mysten/sui/transactions";
import {
  client, keypairFromEnv, readDeployed, writeDeployed, findCreated,
} from "./sui.js";
import {
  REGISTER, MARKET_TYPE, CLOCK_ID, SUI_USD_FEED_ID, feedIdToBytes, fq,
} from "./config.js";

async function main() {
  const kp = keypairFromEnv();
  const sender = kp.getPublicKey().toSuiAddress();
  const d = readDeployed();
  if (!d.packageId || !d.adminCapId) throw new Error("run `pnpm deploy` first (.deployed.json missing ids)");

  const tx = new Transaction();
  tx.moveCall({
    target: fq(d.packageId, "admin", "register_market"),
    typeArguments: [MARKET_TYPE],
    arguments: [
      tx.object(d.adminCapId),
      tx.pure.u16(REGISTER.ltvDefaultBps),
      tx.pure.u64(REGISTER.revertWindowMs),
      tx.pure.u64(REGISTER.minLoosenIntervalMs),
      tx.pure.u16(REGISTER.maxConfBps),
      tx.pure.u64(REGISTER.maxStalenessMs),
      tx.pure.vector("u8", feedIdToBytes(SUI_USD_FEED_ID)),
      tx.pure.address(sender), // publisher_recipient
      tx.pure.address(sender), // stop_recipient
      tx.pure.address(sender), // override_recipient
      tx.object(CLOCK_ID),
    ],
  });

  const res = await client.signAndExecuteTransaction({
    signer: kp,
    transaction: tx,
    options: { showObjectChanges: true, showEffects: true },
  });
  if (res.effects?.status.status !== "success") {
    throw new Error(`register failed: ${JSON.stringify(res.effects?.status)}`);
  }

  const oracleId = findCreated(res.objectChanges, "::oracle::RiskOracle");
  const policyId = findCreated(res.objectChanges, "::policy::RiskPolicy");
  const publisherCapId = findCreated(res.objectChanges, "::caps::RiskOraclePublisherCap");
  const saved = writeDeployed({ oracleId, policyId, publisherCapId });
  console.log("registered:", { oracleId, policyId, publisherCapId });
  console.log("wrote ts/.deployed.json:", saved);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
