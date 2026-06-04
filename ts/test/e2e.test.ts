import { describe, it, expect, beforeAll } from "vitest";
import { Transaction } from "@mysten/sui/transactions";
import { SuiPriceServiceConnection, SuiPythClient } from "@pythnetwork/pyth-sui-js";
import { client, keypairFromEnv, readDeployed, type Deployed } from "../src/sui.js";
import {
  PYTH_STATE_ID, WORMHOLE_STATE_ID, HERMES_ENDPOINT, SUI_USD_FEED_ID,
  CLOCK_ID, MARKET_TYPE, E2E, fq,
} from "../src/config.js";

const TIMEOUT = 90_000;

let d: Deployed;
const kp = keypairFromEnv();
const conn = new SuiPriceServiceConnection(HERMES_ENDPOINT);
const pythClient = new SuiPythClient(client as any, PYTH_STATE_ID, WORMHOLE_STATE_ID);

beforeAll(() => {
  d = readDeployed();
  for (const k of ["packageId", "oracleId", "policyId", "publisherCapId"] as const) {
    if (!d[k]) throw new Error(`.deployed.json missing ${k} — run deploy + register first`);
  }
});

// Build the full update→read_price→new_decision→post_score_and_apply PTB.
// nonce defaults to current+1; override for the replay negative.
async function buildPostTx(nonceOverride?: number) {
  const updates = await conn.getPriceFeedsUpdateData([SUI_USD_FEED_ID]);
  const tx = new Transaction();
  const pioIds = await pythClient.updatePriceFeeds(tx, updates, [SUI_USD_FEED_ID]);
  const pioId = pioIds[0];

  const reading = tx.moveCall({
    target: fq(d.packageId!, "pyth_adapter", "read_price"),
    arguments: [tx.object(d.oracleId!), tx.object(pioId), tx.object(CLOCK_ID)],
  });
  const decision = tx.moveCall({
    target: fq(d.packageId!, "policy", "new_decision"),
    arguments: [tx.pure.u16(E2E.newLtvBps), tx.pure.u8(E2E.newFlags), tx.pure.u8(E2E.reasonCode)],
  });

  const current = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
  const fields = (current.data?.content as any)?.fields ?? {};
  const currentNonce = Number(fields.nonce ?? 0);
  const nonce = nonceOverride ?? currentNonce + 1;

  tx.moveCall({
    target: fq(d.packageId!, "oracle", "post_score_and_apply"),
    typeArguments: [MARKET_TYPE],
    arguments: [
      tx.object(d.oracleId!),
      tx.object(d.policyId!),
      tx.object(d.publisherCapId!),
      tx.pure.u16(E2E.scoreBps),
      decision,
      reading,
      tx.pure.u64(nonce),
      tx.object(CLOCK_ID),
    ],
  });
  return { tx, nonce };
}

describe("pyth read_price e2e (live testnet)", () => {
  it(
    "real PriceInfoObject decodes, passes gates, and mutates oracle state",
    async () => {
      const { tx, nonce } = await buildPostTx();
      const res = await client.signAndExecuteTransaction({
        signer: kp,
        transaction: tx,
        options: { showEvents: true, showEffects: true, showObjectChanges: true },
      });

      // 1. tx succeeded
      expect(res.effects?.status.status).toBe("success");

      // 2. ScorePosted carries our score + nonce (decoded reading survived gates)
      const scorePosted = res.events?.find((e) => e.type.endsWith("::events::ScorePosted"));
      expect(scorePosted, "ScorePosted not emitted").toBeTruthy();
      expect(Number((scorePosted!.parsedJson as any).score_bps)).toBe(E2E.scoreBps);
      expect(Number((scorePosted!.parsedJson as any).nonce)).toBe(nonce);

      // 3. ActionExecuted proves reading passed ALL gates → apply_decision ran
      const actionExecuted = res.events?.find((e) => e.type.endsWith("::events::ActionExecuted"));
      expect(actionExecuted, "ActionExecuted not emitted").toBeTruthy();
      expect(Number((actionExecuted!.parsedJson as any).new_ltv)).toBe(E2E.newLtvBps);

      // 4. decoded reading reached durable state (wait for the fullnode to index the
      //    write, else getObject can read a pre-tx object version → false 0).
      await client.waitForTransaction({ digest: res.digest });
      const after = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
      const afterFields = (after.data?.content as any).fields;
      expect(Number(afterFields.latest_score_bps)).toBe(E2E.scoreBps);
      expect(Number(afterFields.nonce)).toBe(nonce);
    },
    TIMEOUT,
  );

  // PRIMARY negative: replay gate has teeth. Deterministic, no timing dependence.
  // Pass nonce == current oracle nonce (not > current) → post_score_and_apply aborts EReplay=7.
  it(
    "rejects a replayed (non-increasing) nonce with EReplay",
    async () => {
      const current = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
      const currentNonce = Number((current.data?.content as any).fields.nonce ?? 0);
      const { tx } = await buildPostTx(currentNonce); // == current, not > current → EReplay
      // Set an explicit budget so the SDK skips its gas dry-run — a guaranteed-abort
      // tx throws during budget estimation otherwise and never reaches on-chain failure.
      tx.setGasBudget(100_000_000);

      const res = await client.signAndExecuteTransaction({
        signer: kp,
        transaction: tx,
        options: { showEffects: true },
      });

      expect(res.effects?.status.status).toBe("failure");
      // EReplay = 7 in oracle.move; the abort string carries module + code.
      expect(JSON.stringify(res.effects?.status)).toMatch(/oracle.*7|7.*oracle/);
    },
    TIMEOUT,
  );

  // SECONDARY: the staleness branch aborts INSIDE Pyth's get_price_no_older_than
  // (read_price is stricter than post_score's ms check, so our EStaleOracle=6 is
  // unreachable here — see spec §8). A real staleness abort needs a 1s-window oracle
  // (register a market with max_staleness_ms=1000 and pass STALE_ORACLE_ID). Skipped
  // by default; the EReplay test above is the load-bearing negative.
  it.skipIf(process.env.SKIP_STALE === "1" || !process.env.STALE_ORACLE_ID)(
    "stale (un-refreshed) price aborts inside read_price",
    async () => {
      const staleOracle = process.env.STALE_ORACLE_ID!;
      // Update the feed in its own tx so the PriceInfoObject exists on chain...
      const updates = await conn.getPriceFeedsUpdateData([SUI_USD_FEED_ID]);
      const tx = new Transaction();
      const pioIds = await pythClient.updatePriceFeeds(tx, updates, [SUI_USD_FEED_ID]);
      await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });

      // ...wait past the 1s window, then read with a fresh tx against the stale oracle.
      await new Promise((r) => setTimeout(r, 2_000));

      const tx2 = new Transaction();
      tx2.moveCall({
        target: fq(d.packageId!, "pyth_adapter", "read_price"),
        arguments: [tx2.object(staleOracle), tx2.object(pioIds[0]), tx2.object(CLOCK_ID)],
      });
      const res2 = await client.devInspectTransactionBlock({
        sender: kp.getPublicKey().toSuiAddress(),
        transactionBlock: tx2,
      });
      expect(res2.effects?.status.status).toBe("failure");
    },
    TIMEOUT,
  );
});
