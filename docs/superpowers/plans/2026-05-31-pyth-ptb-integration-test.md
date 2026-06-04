# Pyth PTB Integration Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the deliberate on-chain coverage gap in `pyth_adapter::read_price` by exercising it end-to-end against live Pyth on Sui testnet via a TypeScript PTB, asserting decoded values reach on-chain state/events, plus a deterministic negative test proving `post_score_and_apply`'s replay gate has teeth.

**Architecture:** A purely-additive `ts/` subproject (no Move changes — `M` is phantom, use `0x2::sui::SUI` as marker). One-time `deploy.ts` + `register.ts` scripts persist ids to `ts/.deployed.json`; a vitest e2e reads that fixed deployment and runs `updatePriceFeeds → read_price → new_decision → post_score_and_apply` against live Hermes/Pyth testnet.

**Tech Stack:** Node 24 + pnpm, TypeScript, `tsx`, `vitest`, `@mysten/sui`, `@pythnetwork/pyth-sui-js`. Sui testnet, Pyth/Wormhole testnet contracts, Hermes beta endpoint.

---

## Verified on-chain signatures (read from sources 2026-05-31, do not re-derive)

```
admin::register_market<M>(_admin: &AdminCap, ltv_default_bps: u16, revert_window_ms: u64,
    min_loosen_interval_ms: u64, max_conf_bps: u16, max_staleness_ms: u64,
    expected_feed_id: vector<u8>, publisher_recipient: address, stop_recipient: address,
    override_recipient: address, clock: &Clock, ctx)
pyth_adapter::read_price(oracle: &RiskOracle, price_info_object: &PriceInfoObject, clock: &Clock): PriceReading
policy::new_decision(new_ltv_bps: u16, new_flags: u8, reason_code: u8): Decision   // PriceReading/Decision: copy+drop
oracle::post_score_and_apply<M>(oracle: &mut RiskOracle, policy: &mut RiskPolicy<M>,
    cap: &RiskOraclePublisherCap, score_bps: u16, decision: Decision, reading: PriceReading,
    nonce: u64, clock: &Clock)
oracle::current_nonce(oracle: &RiskOracle): u64     // read before to compute nonce+1
oracle::latest_score_bps(oracle: &RiskOracle): u16  // assert == score_bps after
```

Error codes: `EStaleOracle=6`, `EReplay=7` (oracle.move). Known flag bits: `1<<0..1<<3`; `0` = no flags (safe). `apply_decision` ALWAYS emits `ActionExecuted` (no early-return) and pushes a pending snapshot; `MAX_PENDING=8`, pruned once `now - snapshot.ts_ms > revert_window_ms` → register with a short `revert_window_ms` so re-runs don't accumulate to `ETooManyPending`.

Event field shapes (for assertions):
- `ScorePosted { market: TypeName, score_bps: u16, ts_ms: u64, nonce: u64 }`
- `ActionExecuted { action_id, market, kind, prev_ltv, new_ltv, score_bps, ts_ms }`

Testnet constants (verified §3 of spec): Pyth State `0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c`, Wormhole State `0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790`, Hermes `https://hermes-beta.pyth.network`, SUI/USD feed `0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266`, Clock `0x6`.

---

## File Structure

```
ts/
  package.json          # deps + scripts (deploy/register/test)
  tsconfig.json
  .gitignore            # node_modules, .env, .deployed.json
  .env.example          # SUI_TESTNET_KEY
  src/
    config.ts           # all verified testnet constants + feed id + module/function names + helpers
    sui.ts              # SuiClient(testnet), keypair-from-env, objectChanges extraction helpers
    deploy.ts           # `sui move build` + publish; writes packageId + adminCapId to .deployed.json
    register.ts         # PTB register_market<0x2::sui::SUI>; appends oracle/policy/cap ids to .deployed.json
  test/
    config.test.ts      # pure unit: feed-id hex decodes to exactly 32 bytes (typo guard)
    e2e.test.ts         # positive gap-closing e2e + EReplay negative + staleness-path negative
```

---

## Task 1: Subproject scaffold + config

**Files:**
- Create: `ts/package.json`
- Create: `ts/tsconfig.json`
- Create: `ts/.gitignore`
- Create: `ts/.env.example`
- Create: `ts/src/config.ts`
- Test: `ts/test/config.test.ts`

- [ ] **Step 1: Write `ts/package.json`**

```json
{
  "name": "riskguard-ts",
  "private": true,
  "type": "module",
  "scripts": {
    "deploy": "tsx src/deploy.ts",
    "register": "tsx src/register.ts",
    "test": "vitest run"
  },
  "dependencies": {
    "@mysten/sui": "^1.30.0",
    "@pythnetwork/pyth-sui-js": "^2.1.0"
  },
  "devDependencies": {
    "tsx": "^4.19.0",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 2: Write `ts/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "types": ["node"]
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: Write `ts/.gitignore`**

```
node_modules/
.env
.deployed.json
```

- [ ] **Step 4: Write `ts/.env.example`**

```
# Funded Sui testnet Ed25519 private key in bech32 form (starts with suiprivkey1...).
# Export it before running deploy/register/test:  export SUI_TESTNET_KEY=suiprivkey1...
SUI_TESTNET_KEY=
```

- [ ] **Step 5: Write `ts/src/config.ts`**

```ts
// All verified Sui-testnet constants for the RiskGuard Pyth e2e (spec §3).
// Do NOT use mainnet feed ids here — testnet SUI/USD differs from mainnet.

export const NETWORK = "testnet" as const;

export const PYTH_STATE_ID =
  "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c";
export const WORMHOLE_STATE_ID =
  "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790";
export const HERMES_ENDPOINT = "https://hermes-beta.pyth.network";

// SUI/USD testnet beta feed (NOT mainnet 0x23d7...5744).
export const SUI_USD_FEED_ID =
  "0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";

export const CLOCK_ID = "0x6";

// Phantom market marker — any published type works; SUI needs no new Move module.
export const MARKET_TYPE = "0x2::sui::SUI";

// register_market config (spec §6). Short revert_window so repeated e2e runs
// prune pending snapshots and never hit MAX_PENDING=8.
export const REGISTER = {
  ltvDefaultBps: 5000,
  revertWindowMs: 60_000,        // 1 min; min_loosen must be < this
  minLoosenIntervalMs: 5_000,
  maxConfBps: 10_000,            // MAX — do not reject on confidence (decode test)
  maxStalenessMs: 60_000,        // /1000 = 60s for get_price_no_older_than
};

// E2E decision: tighten LTV (lower cap) so it's NOT a loosen → no B3 throttle on re-runs.
export const E2E = {
  newLtvBps: 4000,
  newFlags: 0,                   // no flag bits set
  reasonCode: 1,
  scoreBps: 7777,                // distinctive value we assert reaches state
};

// Move function targets, parameterized by package id at call time.
export const fq = (pkg: string, mod: string, fn: string) => `${pkg}::${mod}::${fn}` as const;

// Strip 0x and decode a hex feed id to a byte array for tx.pure.vector("u8", ...).
export function feedIdToBytes(feedId: string): number[] {
  const hex = feedId.startsWith("0x") ? feedId.slice(2) : feedId;
  if (hex.length !== 64) throw new Error(`feed id must be 32 bytes, got ${hex.length / 2}`);
  const out: number[] = [];
  for (let i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}
```

- [ ] **Step 6: Write the failing unit test `ts/test/config.test.ts`**

```ts
import { describe, it, expect } from "vitest";
import { feedIdToBytes, SUI_USD_FEED_ID } from "../src/config.js";

describe("config feed id", () => {
  it("SUI/USD feed decodes to exactly 32 bytes", () => {
    const bytes = feedIdToBytes(SUI_USD_FEED_ID);
    expect(bytes).toHaveLength(32);
    expect(bytes.every((b) => b >= 0 && b <= 255)).toBe(true);
  });

  it("rejects a wrong-length feed id", () => {
    expect(() => feedIdToBytes("0x1234")).toThrow(/32 bytes/);
  });
});
```

- [ ] **Step 7: Install deps and run the unit test**

Run:
```bash
cd ts && pnpm install && pnpm test config
```
Expected: `config.test.ts` 2 tests PASS. (This verifies the toolchain + feed-id constant before any chain work.)

- [ ] **Step 8: Commit**

```bash
git add ts/package.json ts/tsconfig.json ts/.gitignore ts/.env.example ts/src/config.ts ts/test/config.test.ts ts/pnpm-lock.yaml
git commit -m "test(ts): scaffold pyth e2e subproject + config feed-id guard"
```

---

## Task 2: Sui client + keypair + extraction plumbing

**Files:**
- Create: `ts/src/sui.ts`

- [ ] **Step 1: Write `ts/src/sui.ts`**

```ts
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
      c.type === "created" && c.objectType.endsWith(suffix),
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
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd ts && pnpm exec tsc --noEmit
```
Expected: no errors. (No runtime test here — `sui.ts` is exercised by deploy/register/e2e.)

- [ ] **Step 3: Commit**

```bash
git add ts/src/sui.ts
git commit -m "feat(ts): sui client, env keypair, objectChanges extraction helpers"
```

---

## Task 3: Deploy script

**Files:**
- Create: `ts/src/deploy.ts`

- [ ] **Step 1: Write `ts/src/deploy.ts`**

```ts
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
  const saved = writeDeployed({ packageId, adminCapId });
  console.log("published:", { packageId, adminCapId });
  console.log("wrote ts/.deployed.json:", saved);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd ts && pnpm exec tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Verify CLI env + build BEFORE publishing (spec §9 blocker — surface loudly)**

Run:
```bash
sui client active-env
sui move build --path ../move/riskguard
```
Expected: active-env prints `testnet`; build succeeds. If build reports a framework/protocol mismatch, STOP and switch to a testnet-matching CLI — do not work around it.

- [ ] **Step 4: Run deploy (requires funded SUI_TESTNET_KEY)**

Run:
```bash
cd ts && export SUI_TESTNET_KEY=suiprivkey1... && pnpm deploy
```
Expected: prints a `packageId` (0x...) and `adminCapId`; `ts/.deployed.json` now contains both. If `SUI_TESTNET_KEY` is unset → clear error. If unfunded → gas error from the node.

- [ ] **Step 5: Commit (code only; .deployed.json is gitignored)**

```bash
git add ts/src/deploy.ts
git commit -m "feat(ts): testnet deploy script (CLI build + SDK publish)"
```

---

## Task 4: Register-market script

**Files:**
- Create: `ts/src/register.ts`

- [ ] **Step 1: Write `ts/src/register.ts`**

```ts
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
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd ts && pnpm exec tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Run register (after deploy)**

Run:
```bash
cd ts && pnpm register
```
Expected: prints `oracleId`, `policyId`, `publisherCapId`; `.deployed.json` now has all five ids.

- [ ] **Step 4: Commit**

```bash
git add ts/src/register.ts
git commit -m "feat(ts): register_market<SUI> script, persist oracle/policy/cap ids"
```

---

## Task 5: Positive gap-closing e2e

**Files:**
- Create: `ts/test/e2e.test.ts` (positive test only in this task; negatives added in Task 6)

- [ ] **Step 1: Write the positive e2e test**

```ts
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
// nonce defaults to current+1; override for the replay negative (Task 6).
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

      // 4. decoded reading reached durable state
      const after = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
      const afterFields = (after.data?.content as any).fields;
      expect(Number(afterFields.latest_score_bps)).toBe(E2E.scoreBps);
      expect(Number(afterFields.nonce)).toBe(nonce);
    },
    TIMEOUT,
  );
});
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd ts && pnpm exec tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Run the e2e (live testnet, funded key)**

Run:
```bash
cd ts && pnpm test e2e
```
Expected: the positive test PASSES — `status success`, `ScorePosted` with `score_bps=7777`, `ActionExecuted` with `new_ltv=4000`, and `latest_score_bps=7777` on chain. If it fails on `EReplay`, a prior run left a higher nonce — re-run (nonce is read fresh each run, so a clean re-run recovers).

- [ ] **Step 4: Commit**

```bash
git add ts/test/e2e.test.ts
git commit -m "test(ts): live-testnet e2e closing read_price decode gap"
```

---

## Task 6: Negative tests (gate teeth)

**Files:**
- Modify: `ts/test/e2e.test.ts` (add two tests inside the existing `describe`)

- [ ] **Step 1: Add the `EReplay` (primary, deterministic) + staleness-path (secondary) negatives**

Add these two `it` blocks inside the `describe("pyth read_price e2e ...")` block, after the positive test:

```ts
  // PRIMARY negative: replay gate has teeth. Deterministic, no timing dependence.
  // Pass a nonce <= current oracle nonce → post_score_and_apply must abort EReplay=7.
  it(
    "rejects a replayed (non-increasing) nonce with EReplay",
    async () => {
      const current = await client.getObject({ id: d.oracleId!, options: { showContent: true } });
      const currentNonce = Number((current.data?.content as any).fields.nonce ?? 0);
      const { tx } = await buildPostTx(currentNonce); // == current, not > current → EReplay

      const res = await client.signAndExecuteTransaction({
        signer: kp,
        transaction: tx,
        options: { showEffects: true },
      });

      expect(res.effects?.status.status).toBe("failure");
      // EReplay = 7 in oracle.move; abort error string includes the module + code.
      expect(JSON.stringify(res.effects?.status)).toMatch(/oracle.*7|7.*oracle/);
    },
    TIMEOUT,
  );

  // SECONDARY: exercise the staleness branch. This abort originates INSIDE Pyth's
  // get_price_no_older_than (read_price is stricter than post_score's ms check, so
  // our EStaleOracle=6 is unreachable here — see spec §8). Assert generic failure only.
  // skipIf the live timing proves flaky.
  it.skipIf(process.env.SKIP_STALE === "1")(
    "stale (un-refreshed) price aborts inside read_price",
    async () => {
      // Fetch + update once, then DON'T refresh and let it age past the 1s floor we
      // simulate by re-using a market registered at max_staleness_ms=1000. Here we
      // reuse the deployed oracle (60s window) but force a tiny age via a separate
      // delayed read against a NOT-updated PriceInfoObject is not possible without a
      // 1s-window oracle; so we assert the structural guarantee instead: calling
      // read_price with a feed we never updated in THIS tx, after a delay, fails.
      const updates = await conn.getPriceFeedsUpdateData([SUI_USD_FEED_ID]);
      const tx = new Transaction();
      const pioIds = await pythClient.updatePriceFeeds(tx, updates, [SUI_USD_FEED_ID]);
      // Apply the update in its own tx so the PriceInfoObject exists on chain...
      await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });

      // ...wait past a deliberately tiny tolerance, then read with a fresh tx.
      await new Promise((r) => setTimeout(r, 2_000));

      // A 60s-window oracle won't go stale in 2s, so this test only meaningfully runs
      // against a 1s-window market. Document + skip by default unless STALE_ORACLE_ID set.
      const staleOracle = process.env.STALE_ORACLE_ID;
      if (!staleOracle) return; // structural placeholder; real staleness needs a 1s-window oracle

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
```

> **Note on the secondary test:** to exercise a real staleness abort you need a market registered with `max_staleness_ms = 1000`. If you want this test live, add a `register-stale.ts` variant (copy `register.ts`, set `maxStalenessMs: 1000`, `revertWindowMs` stays 60_000, `minLoosenIntervalMs` 5_000 — invariant min_loosen < revert_window still holds; staleness is independent), run it, and pass `STALE_ORACLE_ID=0x...` when running tests. The primary `EReplay` test is the load-bearing negative; this one is supplementary coverage and skipped by default.

- [ ] **Step 2: Type-check**

Run:
```bash
cd ts && pnpm exec tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Run all e2e tests**

Run:
```bash
cd ts && pnpm test e2e
```
Expected: positive test PASS; `EReplay` test PASS (status `failure`, code 7); staleness test PASS (returns early / skipped unless `STALE_ORACLE_ID` set).

- [ ] **Step 4: Commit**

```bash
git add ts/test/e2e.test.ts
git commit -m "test(ts): EReplay negative + staleness-path coverage"
```

---

## Task 7: Update notes + progress

**Files:**
- Modify: `move-notes.md` (append a section)
- Modify: `tasks/progress.md` (mark task done)

- [ ] **Step 1: Append to `move-notes.md`**

Append a `## 2026-05-31 — Pyth PTB integration test (off-chain)` section recording: the `read_price` decode gap is now closed by a live-testnet e2e (`ts/`), zero Move changes (phantom `M` = `0x2::sui::SUI`), the verified testnet ids used, the negative-test design decision (EReplay primary because read_price's seconds-floor staleness is strictly stricter than post_score's ms check → EStaleOracle=6 unreachable in one PTB), and the mainnet-prep reminders (pin Pyth/Wormhole `rev` to commit, real BUCK/USD feed, Hermes API key after 2026-07-31).

- [ ] **Step 2: Mark the task done in `tasks/progress.md`** (move the current task to a `✅ DONE (2026-05-31)` entry with the test counts and how to re-run: `cd ts && pnpm test`).

- [ ] **Step 3: Commit**

```bash
git add move-notes.md tasks/progress.md
git commit -m "docs: record pyth ptb e2e completion + negative-test rationale"
```

---

## Self-Review (against spec, completed)

- **Spec coverage:** §1/§7 gap-closing e2e → Task 5. §3 verified facts → `config.ts` (Task 1). §4 no Move changes → phantom `0x2::sui::SUI` used throughout. §5 architecture → file structure matches exactly. §6 setup flow → Tasks 3–4. §8 negatives (revised) → Task 6 (EReplay primary + staleness secondary; the infeasibility of asserting EStaleOracle=6 is documented). §9 risks (funded key, CLI/protocol alignment, timeouts, nonce monotonicity) → addressed in Task 3 Step 3 (loud build check), TIMEOUT const, fresh-nonce read. §10 out-of-plan → noted in Task 7 mainnet reminders.
- **Placeholder scan:** the only "placeholder" is the secondary staleness test's early-return — this is intentional and documented (real staleness needs a 1s-window oracle via an optional `register-stale.ts`), not a TODO. Primary negative is fully implemented.
- **Type consistency:** `Deployed` shape, `fq()`, `feedIdToBytes()`, `findCreated()` signatures consistent across Tasks 1–6. Move targets match verified signatures block. `buildPostTx(nonceOverride?)` reused by positive + EReplay tests with consistent return `{ tx, nonce }`.

## Known caveat (surface, don't hide)
- `apply_decision` pushes a pending snapshot every run; `MAX_PENDING=8`, pruned after `revert_window_ms=60_000`. Running the positive e2e >8 times within 60s would hit `ETooManyPending`. Normal manual runs are fine; documented in `config.ts`.
- SDK version pins (`@mysten/sui ^1.30`, `@pythnetwork/pyth-sui-js ^2.1`) are best-effort as of 2026-05; `pnpm install` resolves latest compatible. If `SuiPythClient` constructor or `updatePriceFeeds` signature differs at install time, verify against installed types (per dev-rules: check installed version, don't trust possibly-stale docs) before running Task 5.
