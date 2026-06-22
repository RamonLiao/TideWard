// Demo: simulate the autonomous risk agent's on-chain intervention.
//
// Pulls a LIVE Pyth SUI/USD update, posts a high risk score, and auto-tightens
// the RiskPolicy LTV cap — the exact `update → read_price → new_decision →
// post_score_and_apply` PTB the off-chain scorer would dispatch. No human cap is
// used here; the publisher cap authorizes the agent. The DAO console can REVERT
// the resulting pending action within the policy's revert window.
//
//   pnpm apply [scoreBps] [newLtvBps] [reasonCode]
//   pnpm apply                 # crisis defaults: score 8500 → LTV 3000, reason 2
//   pnpm apply 7777 4000 1     # mirror the e2e config values
//
// Note: tightening (newLtvBps < current cap) bypasses the B3 loosen throttle, so
// repeated runs always apply. A loosen would be rate-limited by minLoosenIntervalMs.
import { Transaction } from "@mysten/sui/transactions";
import { SuiPriceServiceConnection, SuiPythClient } from "@pythnetwork/pyth-sui-js";
import { client, keypairFromEnv, readDeployed } from "./sui.js";
import {
  PYTH_STATE_ID, WORMHOLE_STATE_ID, HERMES_ENDPOINT, SUI_USD_FEED_ID,
  CLOCK_ID, MARKET_TYPE, fq,
} from "./config.js";

// Crisis scenario defaults — high score, tighten the cap hard.
const SCORE_BPS = Number(process.argv[2] ?? 8500);
const NEW_LTV_BPS = Number(process.argv[3] ?? 3000);
const REASON_CODE = Number(process.argv[4] ?? 2);
const NEW_FLAGS = 0;

function assertU(name: string, v: number, max: number) {
  if (!Number.isInteger(v) || v < 0 || v > max) throw new Error(`${name} must be an integer 0-${max}, got ${v}`);
}

async function main() {
  assertU("scoreBps", SCORE_BPS, 65_535);
  assertU("newLtvBps", NEW_LTV_BPS, 10_000);
  assertU("reasonCode", REASON_CODE, 255);

  const kp = keypairFromEnv();
  const d = readDeployed();
  for (const k of ["packageId", "oracleId", "policyId", "publisherCapId"] as const) {
    if (!d[k]) throw new Error(`.deployed.json missing ${k} — run deploy + register first`);
  }

  const conn = new SuiPriceServiceConnection(HERMES_ENDPOINT);
  const pythClient = new SuiPythClient(client as any, PYTH_STATE_ID, WORMHOLE_STATE_ID);

  // Strictly-increasing nonce (replay guard) — read current + 1.
  const current = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
  const currentNonce = Number((current.data?.content as any)?.fields?.nonce ?? 0);
  const nonce = currentNonce + 1;

  const updates = await conn.getPriceFeedsUpdateData([SUI_USD_FEED_ID]);
  const tx = new Transaction();
  const pioIds = await pythClient.updatePriceFeeds(tx, updates, [SUI_USD_FEED_ID]);

  const reading = tx.moveCall({
    target: fq(d.packageId!, "pyth_adapter", "read_price"),
    arguments: [tx.object(d.oracleId!), tx.object(pioIds[0]), tx.object(CLOCK_ID)],
  });
  const decision = tx.moveCall({
    target: fq(d.packageId!, "policy", "new_decision"),
    arguments: [tx.pure.u16(NEW_LTV_BPS), tx.pure.u8(NEW_FLAGS), tx.pure.u8(REASON_CODE)],
  });
  tx.moveCall({
    target: fq(d.packageId!, "oracle", "post_score_and_apply"),
    typeArguments: [MARKET_TYPE],
    arguments: [
      tx.object(d.oracleId!),
      tx.object(d.policyId!),
      tx.object(d.publisherCapId!),
      tx.pure.u16(SCORE_BPS),
      decision,
      reading,
      tx.pure.u64(nonce),
      tx.object(CLOCK_ID),
    ],
  });

  console.log(`agent intervention → score ${SCORE_BPS} bps, LTV→${NEW_LTV_BPS} bps, reason ${REASON_CODE}, nonce ${nonce}`);
  const res = await client.signAndExecuteTransaction({
    signer: kp,
    transaction: tx,
    options: { showEvents: true, showEffects: true },
  });
  if (res.effects?.status.status !== "success") {
    throw new Error(`apply failed: ${JSON.stringify(res.effects?.status)}`);
  }
  const action = res.events?.find((e) => e.type.endsWith("::events::ActionExecuted"));
  console.log("✓ applied:", res.digest);
  console.log("  ActionExecuted:", action ? JSON.stringify(action.parsedJson) : "(not found)");
  console.log("  → open the dApp Markets tab: LTV drops + a new PENDING action appears (revert it in the drawer).");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
