# RiskGuard DAO Console (Frontend dApp) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tron-styled DAO operator console (React dApp, testnet) for RiskGuard: market monitoring, emergency pause/resume, force_protect override, revert, upgrade-timelock management.

**Architecture:** New `app/` Vite + React subproject. Writes (wallet + PTB) go through `@mysten/dapp-kit-react` 2.x; ALL reads (objects, owned caps, events) go through a hand-rolled JSON-RPC fetch helper (`lib/rpc.ts`) because SDK v2 removed `queryEvents` and changed read shapes — JSON-RPC shapes are stable and unit-testable. Polling via TanStack Query. Cap-driven button gating mirrors the contract's asymmetric auth.

**Tech Stack:** React 18, Vite 6, TypeScript, `@mysten/dapp-kit-react` ^2.0 + `@mysten/sui` ^2.0, `@tanstack/react-query`, vitest (pure-function tests only, no jsdom).

**Spec:** `docs/superpowers/specs/2026-06-11-dao-console-ui-design.md`

**Contract ground truth (verified against `move/riskguard/sources/` 2026-06-12):**

- Targets (`PKG` = package id):
  - `PKG::override::force_protect<M>(policy, cap: &OverrideCap<M>, new_ltv_bps: u16, new_flags: u8, reason_code: u8, clock, ctx)`
  - `PKG::policy::revert_action<M>(policy, cap: &OverrideCap<M>, action_id: u64, clock, ctx)`
  - `PKG::oracle::pause_oracle(oracle, cap: &EmergencyStopCap, clock, ctx)` / `resume_oracle(oracle, _: &AdminCap, clock, ctx)`
  - `PKG::upgrade_registry::propose_upgrade(reg, _: &AdminCap, digest: vector<u8>, policy: u8, clock)` / `cancel_upgrade(reg, _: &AdminCap, ctx)` / `init_upgrade_registry(cap: UpgradeCap, _: &AdminCap, ctx)`
  - execute/commit are a hot-potato PTB needing upgrade bytecode → UI shows CLI instructions instead (spec §7).
- Flags: bit0 borrows, bit1 liquidations, bit2 deposits, bit3 withdraws. `MAX_BPS=10000`, `TIMELOCK_MS=259200000`.
- Market type (phantom M): `0x2::sui::SUI`. Clock: `0x6`.
- Existing testnet deploy (`ts/.deployed.json`) predates `override.move`/`upgrade_registry.move` → Task 0 redeploys.

---

## File Structure

```
ts/src/register.ts          (modify: capture emergency/override cap ids)
ts/src/init-registry.ts     (create: wrap UpgradeCap into UpgradeRegistry)
ts/package.json             (modify: add init-registry script)
app/
  package.json  vite.config.ts  tsconfig.json  index.html  .env.local (generated, gitignored)
  scripts/gen-env.mjs        (reads ts/.deployed.json → .env.local)
  src/
    main.tsx  App.tsx  dapp-kit.ts  config.ts  theme.css
    lib/rpc.ts  lib/parsers.ts  lib/abortCodes.ts  lib/monotonic.ts  lib/caps.ts  lib/tx.ts
    hooks/useChain.ts        (TanStack Query wrappers: policy/oracle/registry/caps/events)
    components/TopBar.tsx  Sidebar.tsx  EventTicker.tsx
    components/MarketsPage.tsx  MarketCard.tsx  MarketDrawer.tsx  ForceProtectForm.tsx
    components/EmergencyPage.tsx  OverridePage.tsx  UpgradesPage.tsx
  test/abortCodes.test.ts  monotonic.test.ts  parsers.test.ts  caps.test.ts  tx.test.ts
```

Per-file responsibility: `rpc.ts` = transport only; `parsers.ts` = raw JSON → typed domain objects; `caps.ts` = owned-objects → `CapSet` (gating decisions); `tx.ts` = pure `Transaction` builders; `useChain.ts` = the only file touching TanStack Query; components render and call hooks/builders.

---

### Task 0: Redeploy testnet package with all modules + capture all cap ids

**Files:**
- Modify: `ts/src/register.ts:45-50`
- Create: `ts/src/init-registry.ts`
- Modify: `ts/package.json` (scripts)

- [ ] **Step 1: Extend register.ts to capture the two missing cap ids**

In `ts/src/register.ts` replace lines 45-50 (the `findCreated`/`writeDeployed` block) with:

```ts
  const oracleId = findCreated(res.objectChanges, "::oracle::RiskOracle");
  const policyId = findCreated(res.objectChanges, "::policy::RiskPolicy");
  const publisherCapId = findCreated(res.objectChanges, "::caps::RiskOraclePublisherCap");
  const emergencyCapId = findCreated(res.objectChanges, "::caps::EmergencyStopCap");
  const overrideCapId = findCreated(res.objectChanges, "::caps::OverrideCap");
  const saved = writeDeployed({ oracleId, policyId, publisherCapId, emergencyCapId, overrideCapId });
  console.log("registered:", { oracleId, policyId, publisherCapId, emergencyCapId, overrideCapId });
  console.log("wrote ts/.deployed.json:", saved);
```

Note: `findCreated` already handles generic suffix matching (`OverrideCap<...>` — the `.includes(suffix+"<")` fix from 2026-06-01).

- [ ] **Step 2: Create ts/src/init-registry.ts**

```ts
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
```

- [ ] **Step 3: Capture upgradeCapId in deploy.ts**

In `ts/src/deploy.ts`, after the publish result is parsed, ensure the created `UpgradeCap` id is written to `.deployed.json` as `upgradeCapId` (pattern: `findCreated(res.objectChanges, "::package::UpgradeCap")`). Check the existing write call and add the field; if `deploy.ts` already records it, skip.

- [ ] **Step 4: Add script to ts/package.json**

In `ts/package.json` `"scripts"`, add: `"init-registry": "tsx src/init-registry.ts"` (match the runner used by the existing `deploy`/`register` scripts — copy their command shape).

- [ ] **Step 5: Type-check**

Run: `cd ts && pnpm exec tsc --noEmit`
Expected: clean exit.

- [ ] **Step 6: Redeploy + register + init registry (live, needs SUI_TESTNET_KEY)**

```bash
cd ts
export SUI_TESTNET_KEY=<from keytool>   # same flow as 2026-06-01
pnpm deploy && pnpm register && pnpm init-registry
cat .deployed.json   # must contain: packageId adminCapId oracleId policyId publisherCapId emergencyCapId overrideCapId upgradeRegistryId
```

Expected: all 8 ids present.

- [ ] **Step 7: Sanity e2e against new deploy**

Run: `cd ts && pnpm test e2e`
Expected: positive path + EReplay pass (staleness skip OK).

- [ ] **Step 8: Commit**

```bash
git add ts/src/register.ts ts/src/init-registry.ts ts/src/deploy.ts ts/package.json
git commit -m "feat(ts): capture all cap ids on register + init upgrade registry script"
```

---

### Task 1: Scaffold `app/` (Vite + React + deps + env bridge)

**Files:**
- Create: `app/` via scaffolder, `app/scripts/gen-env.mjs`, `app/src/config.ts`
- Modify: `.gitignore`

- [ ] **Step 1: Scaffold**

```bash
cd /Users/ramonliao/Documents/Code/Project/Web3/Hackathon/2026_Sui_Overflow/Tracks/0-Agentic-Web/01-riskguard
pnpm create vite@latest app --template react-ts
cd app && pnpm install
pnpm add @mysten/dapp-kit-react @mysten/sui @tanstack/react-query
pnpm add -D vitest
```

Then delete scaffold noise: `app/src/App.css`, `app/src/assets/`, `app/public/vite.svg` references. Verify `pnpm ls @mysten/sui` shows a single 2.x entry (no dual install — `app/` has its own node_modules, separate from `ts/`'s 1.45.2; this is two packages, not a conflict).

- [ ] **Step 2: gitignore**

Append to repo-root `.gitignore`:

```
# app build & generated env
app/dist/
app/.env.local
```

- [ ] **Step 3: Create app/scripts/gen-env.mjs**

```js
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
```

Add to `app/package.json` scripts: `"gen-env": "node scripts/gen-env.mjs"`, and `"test": "vitest run"`.

- [ ] **Step 4: Create app/src/config.ts**

```ts
// All chain ids come from Vite env (generated by scripts/gen-env.mjs).
// Never hardcode object ids in source (spec §2).
const env = import.meta.env;

function req(name: string): string {
  const v = env[name];
  if (!v) throw new Error(`${name} missing — run \`pnpm gen-env\` first`);
  return v as string;
}

export const PKG = req("VITE_PKG");
export const RPC_URL = req("VITE_RPC_URL");
export const REGISTRY_ID = req("VITE_REGISTRY_ID");
export const CLOCK_ID = "0x6";

export interface MarketConfig {
  label: string;
  marketType: string; // phantom M
  policyId: string;
  oracleId: string;
}

export const MARKETS: MarketConfig[] = [
  {
    label: "SUI/USD",
    marketType: "0x2::sui::SUI",
    policyId: req("VITE_POLICY_ID"),
    oracleId: req("VITE_ORACLE_ID"),
  },
];

export const MAX_BPS = 10_000;
export const TIMELOCK_MS = 259_200_000; // 72h, mirrors upgrade_registry::TIMELOCK_MS
```

- [ ] **Step 5: Generate env + type-check**

```bash
cd app && pnpm gen-env && pnpm exec tsc --noEmit
```

Expected: `.env.local` written; tsc clean (config.ts not yet imported anywhere — fine).

- [ ] **Step 6: Commit**

```bash
git add app .gitignore
git commit -m "feat(app): scaffold Vite dApp + env bridge from ts/.deployed.json"
```

---

### Task 2: `lib/abortCodes.ts` — Move abort code → human message (TDD)

**Files:**
- Create: `app/src/lib/abortCodes.ts`
- Test: `app/test/abortCodes.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, it, expect } from "vitest";
import { explainAbort, extractAbortCode } from "../src/lib/abortCodes";

describe("explainAbort", () => {
  it("maps known codes to human messages (intent: operator must understand chain rejections)", () => {
    expect(explainAbort(7)).toMatch(/nonce/i);        // EReplay
    expect(explainAbort(23)).toMatch(/protective/i);  // ENotProtective
    expect(explainAbort(42)).toMatch(/timelock/i);    // ETimelockActive
    expect(explainAbort(1001)).toMatch(/cap.*bound|bound.*cap/i); // EWrongPolicy
  });
  it("falls back to raw code for unknown values (fail loud, never hide)", () => {
    expect(explainAbort(9999)).toContain("9999");
  });
});

describe("extractAbortCode", () => {
  it("pulls the code out of a MoveAbort error string", () => {
    const msg = 'MoveAbort(MoveLocation { module: ModuleId { address: c91f..., name: Identifier("oracle") }, function: 3, instruction: 18, function_name: Some("post_score_and_apply") }, 7) in command 2';
    expect(extractAbortCode(msg)).toBe(7);
  });
  it("returns null when no abort code present", () => {
    expect(extractAbortCode("InsufficientGas")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test, verify fails**

Run: `cd app && pnpm exec vitest run test/abortCodes.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement**

```ts
// Move abort code → operator-readable message. Codes verified against
// move/riskguard/sources/* on 2026-06-12. Unknown codes fall through raw.
const TABLE: Record<number, string> = {
  1: "Borrows are paused for this market",
  2: "Liquidations are paused for this market",
  3: "Deposits are paused for this market",
  4: "Withdraws are paused for this market",
  5: "LTV cap exceeded",
  6: "Oracle price is stale (older than max_staleness_ms)",
  7: "Replay rejected: nonce must be strictly increasing",
  8: "Revert window closed (action no longer revertable)",
  9: "Unknown action id (already reverted or pruned)",
  10: "Pyth confidence interval too wide (exceeds max_conf_bps)",
  11: "Too many pending actions (MAX_PENDING=8) — prune or revert first",
  12: "Cap/policy not bound to this oracle",
  13: "Loosen rate-limited: min_loosen_interval_ms cooldown active",
  14: "Oracle paused (kill switch engaged)",
  20: "Invalid bps value (must be ≤ 10000)",
  21: "Bad config (staleness < 1s or feed id not 32 bytes)",
  22: "Decision sets an undefined flag bit",
  23: "Not protective: override may only lower LTV or add pause flags",
  24: "Override is a no-op (nothing changes)",
  30: "Wrong Pyth feed for this oracle",
  31: "Invalid price (must be positive)",
  40: "An upgrade proposal is already pending — cancel it first",
  41: "No pending upgrade proposal",
  42: "Timelock still active (72h not elapsed)",
  43: "Proposed policy more permissive than the UpgradeCap allows",
  1001: "This cap is not bound to this policy (anti-spoof check)",
};

export function explainAbort(code: number): string {
  return TABLE[code] ?? `Move abort code ${code} (unmapped)`;
}

/** Parses "...MoveAbort(..., <code>)..." out of a wallet/node error string. */
export function extractAbortCode(message: string): number | null {
  const m = message.match(/MoveAbort\(.*,\s*(\d+)\)/s);
  return m ? Number(m[1]) : null;
}

export function explainTxError(message: string): string {
  const code = extractAbortCode(message);
  return code === null ? message : explainAbort(code);
}
```

- [ ] **Step 4: Run test, verify passes**

Run: `cd app && pnpm exec vitest run test/abortCodes.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/lib/abortCodes.ts app/test/abortCodes.test.ts
git commit -m "feat(app): abort code → human message mapping"
```

---

### Task 3: `lib/monotonic.ts` — frontend monotonic-protective validation (TDD)

**Files:**
- Create: `app/src/lib/monotonic.ts`
- Test: `app/test/monotonic.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, it, expect } from "vitest";
import { validateForceProtect } from "../src/lib/monotonic";

// Intent: mirror override.move's monotonic-protective rule so the submit
// button can be disabled with an explanation BEFORE the chain aborts (23/24).
// The contract remains the source of truth.
describe("validateForceProtect", () => {
  const cur = { ltvBps: 4000, flags: 0b0001 };

  it("allows lowering LTV", () => {
    expect(validateForceProtect(cur, 3000, 0b0001)).toEqual({ ok: true });
  });
  it("allows adding a flag", () => {
    expect(validateForceProtect(cur, 4000, 0b0011)).toEqual({ ok: true });
  });
  it("rejects raising LTV (would loosen)", () => {
    const r = validateForceProtect(cur, 5000, 0b0001);
    expect(r.ok).toBe(false);
    expect(r.ok === false && r.reason).toMatch(/lower|raise/i);
  });
  it("rejects clearing a flag (would loosen)", () => {
    const r = validateForceProtect(cur, 4000, 0b0000);
    expect(r.ok).toBe(false);
  });
  it("rejects a no-op (contract aborts 24)", () => {
    const r = validateForceProtect(cur, 4000, 0b0001);
    expect(r.ok).toBe(false);
    expect(r.ok === false && r.reason).toMatch(/no-?op|nothing/i);
  });
  it("rejects undefined flag bits (contract KNOWN_FLAGS = bits 0-3)", () => {
    const r = validateForceProtect(cur, 3000, 0b10001);
    expect(r.ok).toBe(false);
  });
  it("rejects ltv > MAX_BPS and non-integer/negative input (monkey-proof)", () => {
    expect(validateForceProtect(cur, 10001, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, -1, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, 39.5, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, Number.NaN, 0b0001).ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test, verify fails**

Run: `cd app && pnpm exec vitest run test/monotonic.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
export const KNOWN_FLAGS = 0b1111; // bits 0-3, mirrors policy.move KNOWN_FLAGS
const MAX_BPS = 10_000;

export const FLAG_LABELS: { bit: number; label: string }[] = [
  { bit: 1 << 0, label: "Borrows paused" },
  { bit: 1 << 1, label: "Liquidations paused" },
  { bit: 1 << 2, label: "Deposits paused" },
  { bit: 1 << 3, label: "Withdraws paused" },
];

export type Validation = { ok: true } | { ok: false; reason: string };

export function validateForceProtect(
  current: { ltvBps: number; flags: number },
  newLtvBps: number,
  newFlags: number,
): Validation {
  if (!Number.isInteger(newLtvBps) || newLtvBps < 0 || newLtvBps > MAX_BPS)
    return { ok: false, reason: `LTV must be an integer in [0, ${MAX_BPS}] bps` };
  if (!Number.isInteger(newFlags) || newFlags < 0 || (newFlags & ~KNOWN_FLAGS) !== 0)
    return { ok: false, reason: "Flags contain undefined bits (only bits 0-3 exist)" };
  if (newLtvBps > current.ltvBps)
    return { ok: false, reason: "Override may only LOWER the LTV cap, not raise it" };
  if ((current.flags & newFlags) !== current.flags)
    return { ok: false, reason: "Override may only ADD pause flags, not clear them" };
  if (newLtvBps === current.ltvBps && newFlags === current.flags)
    return { ok: false, reason: "No-op: nothing changes (chain would abort with code 24)" };
  return { ok: true };
}
```

- [ ] **Step 4: Run test, verify passes**

Run: `cd app && pnpm exec vitest run test/monotonic.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/lib/monotonic.ts app/test/monotonic.test.ts
git commit -m "feat(app): monotonic-protective frontend validation"
```

---

### Task 4: `lib/rpc.ts` + `lib/parsers.ts` — JSON-RPC reads + typed parsers (TDD)

**Files:**
- Create: `app/src/lib/rpc.ts`, `app/src/lib/parsers.ts`
- Test: `app/test/parsers.test.ts`

Rationale (locked decision): SDK v2 removed `suix_queryEvents` from the client (gRPC streaming only) and moved reads to `client.core.*` with different shapes. Raw JSON-RPC keeps all read shapes stable + parsers unit-testable without a network.

- [ ] **Step 1: Create app/src/lib/rpc.ts (transport only — no parsing logic here)**

```ts
import { RPC_URL } from "../config";

let nextId = 1;

export async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`RPC ${method}: ${body.error.message}`);
  return body.result as T;
}

export function getObject(objectId: string) {
  return rpc<{ data?: { content?: { dataType: string; type: string; fields: Record<string, unknown> } } }>(
    "sui_getObject", [objectId, { showContent: true }],
  );
}

export function getOwnedObjects(owner: string, structType: string) {
  return rpc<{ data: { data?: { objectId: string; type?: string } }[] }>(
    "suix_getOwnedObjects",
    [owner, { filter: { StructType: structType }, options: { showType: true } }, null, 50],
  );
}

/** All riskguard events live in the events module — one query covers the ticker. */
export function queryPackageEvents(pkg: string, limit = 50) {
  return rpc<{ data: { id: { txDigest: string; eventSeq: string }; type: string; parsedJson: Record<string, unknown>; timestampMs?: string }[] }>(
    "suix_queryEvents",
    [{ MoveEventModule: { package: pkg, module: "events" } }, null, limit, true /* descending */],
  );
}
```

- [ ] **Step 2: Write failing parser test**

`app/test/parsers.test.ts` — fixtures mimic real `sui_getObject` JSON-RPC shapes (u64 as string, nested struct as `{type, fields}`):

```ts
import { describe, it, expect } from "vitest";
import { parsePolicy, parseOracle, parseRegistry, parseEvent } from "../src/lib/parsers";

const policyFixture = {
  data: { content: { dataType: "moveObject", type: "0xPKG::policy::RiskPolicy<0x2::sui::SUI>", fields: {
    ltv_bps: 4000, ltv_default_bps: 5000, flags: 1,
    revert_window_ms: "60000", min_loosen_interval_ms: "3600000",
    last_loosen_ts_ms: "0", max_conf_bps: 500, oracle_id: "0xabc",
    next_action_id: "3",
    pending_actions: [
      { type: "0xPKG::policy::ActionSnapshot", fields: {
        action_id: "2", kind: 1, prev_ltv_bps: 5000, prev_flags: 0, reason_code: 9, ts_ms: "1718000000000" } },
    ],
    reserved: [],
  } } },
};

describe("parsePolicy", () => {
  it("converts u64 strings to numbers and unwraps nested snapshots", () => {
    const p = parsePolicy(policyFixture as never);
    expect(p.ltvBps).toBe(4000);
    expect(p.revertWindowMs).toBe(60000);
    expect(p.pending).toHaveLength(1);
    expect(p.pending[0]).toMatchObject({ actionId: 2, kind: 1, prevLtvBps: 5000, tsMs: 1718000000000 });
  });
  it("throws loudly on a missing/foreign object instead of returning garbage", () => {
    expect(() => parsePolicy({ data: {} } as never)).toThrow(/content/i);
  });
});

describe("parseOracle", () => {
  it("reads active/nonce/staleness", () => {
    const o = parseOracle({ data: { content: { dataType: "moveObject", type: "0xPKG::oracle::RiskOracle", fields: {
      active: true, latest_score_bps: 7777, latest_score_ts_ms: "1718000000000",
      nonce: "5", max_staleness_ms: "60000", expected_feed_id: [1, 2],
    } } } } as never);
    expect(o).toMatchObject({ active: true, latestScoreBps: 7777, nonce: 5, maxStalenessMs: 60000 });
  });
});

describe("parseRegistry", () => {
  it("handles no pending (Option none)", () => {
    const r = parseRegistry({ data: { content: { dataType: "moveObject", type: "0xPKG::upgrade_registry::UpgradeRegistry", fields: {
      timelock_ms: "259200000", epoch: "1", pending: null,
      cap: { type: "0x2::package::UpgradeCap", fields: { version: "1", policy: 0 } },
    } } } } as never);
    expect(r.pending).toBeNull();
    expect(r.capVersion).toBe(1);
  });
  it("handles a pending proposal (Option some)", () => {
    const r = parseRegistry({ data: { content: { dataType: "moveObject", type: "t", fields: {
      timelock_ms: "259200000", epoch: "2",
      pending: { type: "0xPKG::upgrade_registry::PendingUpgrade", fields: {
        digest: [1], policy: 0, proposed_at_ms: "1718000000000", epoch: "2" } },
      cap: { type: "0x2::package::UpgradeCap", fields: { version: "1", policy: 0 } },
    } } } } as never);
    expect(r.pending).toMatchObject({ proposedAtMs: 1718000000000, policy: 0 });
  });
});

describe("parseEvent", () => {
  it("extracts short name + keeps payload", () => {
    const e = parseEvent({
      id: { txDigest: "D", eventSeq: "0" },
      type: "0xPKG::events::OverrideApplied",
      parsedJson: { reason_code: 2 },
      timestampMs: "1718000000000",
    } as never);
    expect(e.name).toBe("OverrideApplied");
    expect(e.tsMs).toBe(1718000000000);
    expect(e.json).toEqual({ reason_code: 2 });
  });
});
```

- [ ] **Step 3: Run test, verify fails**

Run: `cd app && pnpm exec vitest run test/parsers.test.ts`
Expected: FAIL.

- [ ] **Step 4: Implement app/src/lib/parsers.ts**

```ts
// Raw JSON-RPC object/event payloads → typed domain objects.
// u64 arrives as string, u8/u16 as number, nested structs as {type, fields}.

type RawObject = { data?: { content?: { dataType: string; type: string; fields: Record<string, any> } } };

function fields(raw: RawObject, what: string): Record<string, any> {
  const c = raw.data?.content;
  if (!c || c.dataType !== "moveObject") throw new Error(`${what}: object has no moveObject content`);
  return c.fields;
}

const n = (v: string | number): number => Number(v);

export interface PendingAction {
  actionId: number; kind: number; prevLtvBps: number;
  prevFlags: number; reasonCode: number; tsMs: number;
}
export interface PolicyState {
  ltvBps: number; ltvDefaultBps: number; flags: number;
  revertWindowMs: number; minLoosenIntervalMs: number; lastLoosenTsMs: number;
  maxConfBps: number; oracleId: string; pending: PendingAction[];
}

export function parsePolicy(raw: RawObject): PolicyState {
  const f = fields(raw, "RiskPolicy");
  return {
    ltvBps: n(f.ltv_bps), ltvDefaultBps: n(f.ltv_default_bps), flags: n(f.flags),
    revertWindowMs: n(f.revert_window_ms), minLoosenIntervalMs: n(f.min_loosen_interval_ms),
    lastLoosenTsMs: n(f.last_loosen_ts_ms), maxConfBps: n(f.max_conf_bps),
    oracleId: String(f.oracle_id),
    pending: (f.pending_actions as any[]).map((s) => ({
      actionId: n(s.fields.action_id), kind: n(s.fields.kind),
      prevLtvBps: n(s.fields.prev_ltv_bps), prevFlags: n(s.fields.prev_flags),
      reasonCode: n(s.fields.reason_code), tsMs: n(s.fields.ts_ms),
    })),
  };
}

export interface OracleState {
  active: boolean; latestScoreBps: number; latestScoreTsMs: number;
  nonce: number; maxStalenessMs: number;
}

export function parseOracle(raw: RawObject): OracleState {
  const f = fields(raw, "RiskOracle");
  return {
    active: Boolean(f.active), latestScoreBps: n(f.latest_score_bps),
    latestScoreTsMs: n(f.latest_score_ts_ms), nonce: n(f.nonce),
    maxStalenessMs: n(f.max_staleness_ms),
  };
}

export interface RegistryState {
  timelockMs: number; epoch: number; capVersion: number;
  pending: { digest: number[]; policy: number; proposedAtMs: number; epoch: number } | null;
}

export function parseRegistry(raw: RawObject): RegistryState {
  const f = fields(raw, "UpgradeRegistry");
  const p = f.pending;
  return {
    timelockMs: n(f.timelock_ms), epoch: n(f.epoch),
    capVersion: n(f.cap.fields.version),
    pending: p
      ? { digest: p.fields.digest as number[], policy: n(p.fields.policy),
          proposedAtMs: n(p.fields.proposed_at_ms), epoch: n(p.fields.epoch) }
      : null,
  };
}

export interface ChainEvent {
  key: string; name: string; tsMs: number; json: Record<string, unknown>;
}

export function parseEvent(raw: { id: { txDigest: string; eventSeq: string }; type: string; parsedJson: Record<string, unknown>; timestampMs?: string }): ChainEvent {
  return {
    key: `${raw.id.txDigest}:${raw.id.eventSeq}`,
    name: raw.type.split("::").pop() ?? raw.type,
    tsMs: raw.timestampMs ? Number(raw.timestampMs) : 0,
    json: raw.parsedJson,
  };
}
```

- [ ] **Step 5: Run test, verify passes**

Run: `cd app && pnpm exec vitest run test/parsers.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/src/lib/rpc.ts app/src/lib/parsers.ts app/test/parsers.test.ts
git commit -m "feat(app): JSON-RPC transport + typed chain-state parsers"
```

---

### Task 5: `lib/caps.ts` — cap discovery & gating (TDD)

**Files:**
- Create: `app/src/lib/caps.ts`
- Test: `app/test/caps.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, it, expect } from "vitest";
import { resolveCaps, gate } from "../src/lib/caps";

// Intent: buttons must mirror contract auth exactly — pause needs
// EmergencyStopCap, resume needs AdminCap, override/revert need OverrideCap<M>.
const PKG = "0xPKG";
describe("resolveCaps", () => {
  it("maps owned objects to cap ids", () => {
    const caps = resolveCaps(PKG, [
      { objectId: "0x1", type: `${PKG}::caps::AdminCap` },
      { objectId: "0x2", type: `${PKG}::caps::EmergencyStopCap` },
      { objectId: "0x3", type: `${PKG}::caps::OverrideCap<0x2::sui::SUI>` },
    ]);
    expect(caps.adminCapId).toBe("0x1");
    expect(caps.emergencyCapId).toBe("0x2");
    expect(caps.overrideCapIds["0x2::sui::SUI"]).toBe("0x3");
  });
  it("ignores foreign-package lookalikes (anti-spoof: type prefix must match PKG)", () => {
    const caps = resolveCaps(PKG, [{ objectId: "0x9", type: "0xEVIL::caps::AdminCap" }]);
    expect(caps.adminCapId).toBeNull();
  });
});

describe("gate", () => {
  const none = resolveCaps(PKG, []);
  it("disabled with the missing-cap name in the tooltip", () => {
    const g = gate(none.emergencyCapId, "EmergencyStopCap");
    expect(g.enabled).toBe(false);
    expect(g.tooltip).toContain("EmergencyStopCap");
  });
  it("enabled when cap held", () => {
    expect(gate("0x2", "EmergencyStopCap")).toEqual({ enabled: true, tooltip: null });
  });
});
```

- [ ] **Step 2: Run test, verify fails**

Run: `cd app && pnpm exec vitest run test/caps.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
export interface CapSet {
  adminCapId: string | null;
  emergencyCapId: string | null;
  publisherCapId: string | null;
  /** marketType → OverrideCap object id */
  overrideCapIds: Record<string, string>;
}

export function resolveCaps(pkg: string, owned: { objectId: string; type?: string }[]): CapSet {
  const caps: CapSet = { adminCapId: null, emergencyCapId: null, publisherCapId: null, overrideCapIds: {} };
  for (const o of owned) {
    const t = o.type ?? "";
    if (!t.startsWith(`${pkg}::caps::`)) continue; // anti-spoof: exact package
    if (t === `${pkg}::caps::AdminCap`) caps.adminCapId = o.objectId;
    else if (t === `${pkg}::caps::EmergencyStopCap`) caps.emergencyCapId = o.objectId;
    else if (t === `${pkg}::caps::RiskOraclePublisherCap`) caps.publisherCapId = o.objectId;
    else {
      const m = t.match(/::caps::OverrideCap<(.+)>$/);
      if (m) caps.overrideCapIds[m[1]] = o.objectId;
    }
  }
  return caps;
}

export function gate(capId: string | null, capName: string): { enabled: boolean; tooltip: string | null } {
  return capId
    ? { enabled: true, tooltip: null }
    : { enabled: false, tooltip: `Requires ${capName} (not held by connected wallet)` };
}
```

- [ ] **Step 4: Run test, verify passes**

Run: `cd app && pnpm exec vitest run test/caps.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/lib/caps.ts app/test/caps.test.ts
git commit -m "feat(app): cap discovery + button gating helpers"
```

---

### Task 6: `lib/tx.ts` — PTB builders (TDD-light)

**Files:**
- Create: `app/src/lib/tx.ts`
- Test: `app/test/tx.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, it, expect } from "vitest";
import { buildPause, buildResume, buildForceProtect, buildRevert, buildProposeUpgrade, buildCancelUpgrade } from "../src/lib/tx";

// Intent: every builder must target the verified Move entry with the right
// type args. We assert on the serialized tx JSON (no network needed).
const ids = {
  pkg: "0x" + "1".repeat(64), oracle: "0x" + "2".repeat(64), policy: "0x" + "3".repeat(64),
  registry: "0x" + "4".repeat(64), cap: "0x" + "5".repeat(64),
};
const mkt = "0x2::sui::SUI";

async function targets(tx: { toJSON(): Promise<string> }) {
  const j = JSON.parse(await tx.toJSON());
  return j.commands.map((c: any) => c.MoveCall?.function && `${c.MoveCall.module}::${c.MoveCall.function}`);
}

describe("tx builders", () => {
  it("pause/resume target oracle module", async () => {
    expect(await targets(buildPause(ids.pkg, ids.oracle, ids.cap))).toEqual(["oracle::pause_oracle"]);
    expect(await targets(buildResume(ids.pkg, ids.oracle, ids.cap))).toEqual(["oracle::resume_oracle"]);
  });
  it("force_protect targets override module with the market type arg", async () => {
    const tx = buildForceProtect(ids.pkg, ids.policy, ids.cap, mkt, { newLtvBps: 3000, newFlags: 1, reasonCode: 2 });
    const j = JSON.parse(await tx.toJSON());
    expect(j.commands[0].MoveCall.function).toBe("force_protect");
    expect(j.commands[0].MoveCall.typeArguments).toEqual([mkt]);
  });
  it("revert_action carries the action id", async () => {
    expect(await targets(buildRevert(ids.pkg, ids.policy, ids.cap, mkt, 2))).toEqual(["policy::revert_action"]);
  });
  it("upgrade propose/cancel target the registry", async () => {
    expect(await targets(buildProposeUpgrade(ids.pkg, ids.registry, ids.cap, [1, 2], 0))).toEqual(["upgrade_registry::propose_upgrade"]);
    expect(await targets(buildCancelUpgrade(ids.pkg, ids.registry, ids.cap))).toEqual(["upgrade_registry::cancel_upgrade"]);
  });
});
```

- [ ] **Step 2: Run test, verify fails**

Run: `cd app && pnpm exec vitest run test/tx.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
import { Transaction } from "@mysten/sui/transactions";
import { CLOCK_ID } from "../config";

const fq = (pkg: string, mod: string, fn: string) => `${pkg}::${mod}::${fn}` as const;

export function buildPause(pkg: string, oracleId: string, emergencyCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "oracle", "pause_oracle"),
    arguments: [tx.object(oracleId), tx.object(emergencyCapId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export function buildResume(pkg: string, oracleId: string, adminCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "oracle", "resume_oracle"),
    arguments: [tx.object(oracleId), tx.object(adminCapId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export interface ForceProtectInput { newLtvBps: number; newFlags: number; reasonCode: number; }

export function buildForceProtect(
  pkg: string, policyId: string, overrideCapId: string, marketType: string, input: ForceProtectInput,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "override", "force_protect"),
    typeArguments: [marketType],
    arguments: [
      tx.object(policyId), tx.object(overrideCapId),
      tx.pure.u16(input.newLtvBps), tx.pure.u8(input.newFlags), tx.pure.u8(input.reasonCode),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function buildRevert(
  pkg: string, policyId: string, overrideCapId: string, marketType: string, actionId: number,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "policy", "revert_action"),
    typeArguments: [marketType],
    arguments: [tx.object(policyId), tx.object(overrideCapId), tx.pure.u64(actionId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export function buildProposeUpgrade(
  pkg: string, registryId: string, adminCapId: string, digest: number[], policy: number,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "upgrade_registry", "propose_upgrade"),
    arguments: [
      tx.object(registryId), tx.object(adminCapId),
      tx.pure.vector("u8", digest), tx.pure.u8(policy), tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function buildCancelUpgrade(pkg: string, registryId: string, adminCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "upgrade_registry", "cancel_upgrade"),
    arguments: [tx.object(registryId), tx.object(adminCapId)],
  });
  return tx;
}
```

Note: Move signatures take trailing `ctx: &TxContext` — supplied implicitly by the runtime, never an argument. `cancel_upgrade(reg, _, ctx)` has no clock. If `tx.toJSON()` shape differs in the installed `@mysten/sui` 2.x (check `node_modules/@mysten/sui` types if the test errors), adapt the test's `targets()` helper to the actual serialized shape — do NOT change the builders.

- [ ] **Step 4: Run test, verify passes**

Run: `cd app && pnpm exec vitest run test/tx.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/lib/tx.ts app/test/tx.test.ts
git commit -m "feat(app): PTB builders for all console actions"
```

---

### Task 7: dapp-kit wiring + hooks (`useChain.ts`)

**Files:**
- Create: `app/src/dapp-kit.ts`, `app/src/hooks/useChain.ts`
- Modify: `app/src/main.tsx`

- [ ] **Step 1: Create app/src/dapp-kit.ts**

```ts
import { createDAppKit } from "@mysten/dapp-kit-react";
import { SuiGrpcClient } from "@mysten/sui/grpc";

export const dAppKit = createDAppKit({
  networks: ["testnet"],
  defaultNetwork: "testnet",
  createClient: (network) =>
    new SuiGrpcClient({ network, baseUrl: "https://fullnode.testnet.sui.io:443" }),
});

declare module "@mysten/dapp-kit-react" {
  interface Register {
    dAppKit: typeof dAppKit;
  }
}
```

- [ ] **Step 2: Create app/src/hooks/useChain.ts**

```ts
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCurrentAccount, useCurrentClient, useDAppKit } from "@mysten/dapp-kit-react";
import { Transaction } from "@mysten/sui/transactions";
import { getObject, getOwnedObjects, queryPackageEvents } from "../lib/rpc";
import { parsePolicy, parseOracle, parseRegistry, parseEvent } from "../lib/parsers";
import { resolveCaps, type CapSet } from "../lib/caps";
import { explainTxError } from "../lib/abortCodes";
import { PKG, REGISTRY_ID, type MarketConfig } from "../config";

const POLL_MS = 7000;

export function usePolicy(m: MarketConfig) {
  return useQuery({
    queryKey: ["policy", m.policyId],
    queryFn: async () => parsePolicy(await getObject(m.policyId)),
    refetchInterval: POLL_MS,
  });
}

export function useOracle(m: MarketConfig) {
  return useQuery({
    queryKey: ["oracle", m.oracleId],
    queryFn: async () => parseOracle(await getObject(m.oracleId)),
    refetchInterval: POLL_MS,
  });
}

export function useRegistry() {
  return useQuery({
    queryKey: ["registry", REGISTRY_ID],
    queryFn: async () => parseRegistry(await getObject(REGISTRY_ID)),
    refetchInterval: POLL_MS,
  });
}

export function useEvents() {
  return useQuery({
    queryKey: ["events", PKG],
    queryFn: async () => (await queryPackageEvents(PKG)).data.map(parseEvent),
    refetchInterval: POLL_MS,
  });
}

const CAP_TYPES = ["AdminCap", "EmergencyStopCap", "RiskOraclePublisherCap", "OverrideCap"];

export function useCaps(): { caps: CapSet; isPending: boolean } {
  const account = useCurrentAccount();
  const q = useQuery({
    queryKey: ["caps", account?.address],
    queryFn: async () => {
      const owned = await Promise.all(
        CAP_TYPES.map((t) => getOwnedObjects(account!.address, `${PKG}::caps::${t}`)),
      );
      const flat = owned.flatMap((page) =>
        page.data.map((d) => ({ objectId: d.data!.objectId, type: d.data!.type })),
      );
      return resolveCaps(PKG, flat);
    },
    enabled: !!account,
    refetchInterval: 30_000,
  });
  return { caps: q.data ?? resolveCaps(PKG, []), isPending: q.isPending && !!account };
}

/** Sign+execute, wait for indexing, refresh all chain queries. Throws human-readable errors. */
export function useExecute() {
  const dAppKit = useDAppKit();
  const client = useCurrentClient();
  const queryClient = useQueryClient();
  return async (tx: Transaction) => {
    try {
      const result = await dAppKit.signAndExecuteTransaction({ transaction: tx });
      if (result.FailedTransaction) {
        throw new Error(explainTxError(result.FailedTransaction.status.error?.message ?? "Transaction failed"));
      }
      await client.waitForTransaction({ digest: result.Transaction.digest });
      await queryClient.invalidateQueries(); // refresh policy/oracle/registry/events/caps
      return result.Transaction.digest;
    } catch (e) {
      throw new Error(explainTxError(e instanceof Error ? e.message : String(e)));
    }
  };
}
```

- [ ] **Step 3: Wire providers in app/src/main.tsx**

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { DAppKitProvider } from "@mysten/dapp-kit-react";
import { dAppKit } from "./dapp-kit";
import App from "./App";
import "./theme.css";

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <DAppKitProvider dAppKit={dAppKit}>
        <App />
      </DAppKitProvider>
    </QueryClientProvider>
  </React.StrictMode>,
);
```

(`theme.css` arrives in Task 8 — create an empty `app/src/theme.css` now so tsc/vite don't break.)

- [ ] **Step 4: Type-check**

Run: `cd app && pnpm exec tsc --noEmit`
Expected: clean. (App.tsx still scaffold-default; replaced next task.)

- [ ] **Step 5: Commit**

```bash
git add app/src/dapp-kit.ts app/src/hooks/useChain.ts app/src/main.tsx app/src/theme.css
git commit -m "feat(app): dapp-kit wiring + chain query/execute hooks"
```

---

### Task 8: Tron theme + app shell (TopBar / Sidebar / EventTicker)

**Files:**
- Create: `app/src/theme.css` (fill), `app/src/components/TopBar.tsx`, `app/src/components/Sidebar.tsx`, `app/src/components/EventTicker.tsx`
- Modify: `app/src/App.tsx`, `app/index.html`

- [ ] **Step 1: Fill app/src/theme.css (Tron tokens — spec §8)**

```css
:root {
  --bg: #050a0f;
  --grid: rgba(0, 229, 255, 0.05);
  --cyan: #00e5ff;
  --cyan-dim: #5a8a99;
  --cyan-soft: #7fdbff;
  --orange: #ff6b35;
  --red: #ff3b3b;
  --green: #00ff9f;
  --panel: rgba(0, 229, 255, 0.04);
  --border: rgba(0, 229, 255, 0.4);
  --border-dim: rgba(0, 229, 255, 0.2);
  --glow-cyan: 0 0 14px rgba(0, 229, 255, 0.18);
  --glow-orange: 0 0 10px rgba(255, 107, 53, 0.35);
  --font-mono: "SF Mono", ui-monospace, Menlo, monospace;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  background-image:
    linear-gradient(var(--grid) 1px, transparent 1px),
    linear-gradient(90deg, var(--grid) 1px, transparent 1px);
  background-size: 28px 28px;
  color: #bfeaf5;
  font-family: var(--font-mono);
}

.app { display: grid; grid-template-rows: 56px 1fr 36px; height: 100vh; }
.main { display: grid; grid-template-columns: 180px 1fr; overflow: hidden; }
.page { padding: 20px; overflow-y: auto; }

.topbar {
  display: flex; align-items: center; gap: 20px; padding: 0 20px;
  border-bottom: 1px solid var(--border);
  box-shadow: 0 8px 12px -12px rgba(0, 229, 255, 0.6);
}
.brand { color: var(--cyan); letter-spacing: 3px; text-shadow: 0 0 8px rgba(0, 229, 255, 0.8); }
.spacer { flex: 1; }

.sidebar { border-right: 1px solid var(--border-dim); padding: 12px 0; }
.nav-item {
  display: block; width: 100%; text-align: left; padding: 10px 18px;
  background: none; border: none; color: var(--cyan-dim);
  font-family: var(--font-mono); font-size: 13px; cursor: pointer;
}
.nav-item.active { color: var(--cyan); background: var(--panel); border-right: 2px solid var(--cyan); }

.card {
  background: var(--panel); border: 1px solid var(--border); border-radius: 4px;
  padding: 14px; box-shadow: var(--glow-cyan); cursor: pointer;
}
.card h3 { margin: 0; color: var(--cyan); text-shadow: 0 0 6px rgba(0, 229, 255, 0.7); font-size: 14px; }
.metric { font-size: 26px; color: #fff; margin: 8px 0; text-shadow: 0 0 10px rgba(0, 229, 255, 0.5); }
.dim { color: var(--cyan-dim); font-size: 11px; }
.status-ok { color: var(--green); text-shadow: 0 0 6px var(--green); }
.status-warn { color: var(--orange); text-shadow: 0 0 5px rgba(255, 107, 53, 0.8); }
.status-bad { color: var(--red); text-shadow: 0 0 6px rgba(255, 59, 59, 0.8); }

.btn {
  background: none; border: 1px solid var(--cyan); color: var(--cyan);
  font-family: var(--font-mono); font-size: 12px; padding: 6px 14px;
  border-radius: 2px; cursor: pointer;
}
.btn:hover:not(:disabled) { box-shadow: var(--glow-cyan); }
.btn:disabled { border-color: var(--cyan-dim); color: var(--cyan-dim); cursor: not-allowed; opacity: 0.5; }
.btn-danger { border-color: var(--orange); color: var(--orange); }
.btn-danger:hover:not(:disabled) { box-shadow: var(--glow-orange); }

.input {
  background: rgba(0, 229, 255, 0.06); border: 1px solid var(--border-dim);
  color: #fff; font-family: var(--font-mono); padding: 6px 10px; border-radius: 2px;
}

.ticker {
  display: flex; align-items: center; gap: 16px; padding: 0 16px; overflow-x: auto;
  white-space: nowrap; border-top: 1px dashed var(--border-dim);
  font-size: 11px; color: var(--cyan-dim);
}

.drawer {
  position: fixed; top: 56px; right: 0; bottom: 36px; width: 380px;
  background: #07111a; border-left: 1px solid var(--border);
  box-shadow: -10px 0 30px rgba(0, 229, 255, 0.15);
  padding: 18px; overflow-y: auto; z-index: 10;
}

.grid-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 14px; }
.list-rows .card { display: flex; align-items: center; gap: 20px; margin-bottom: 8px; }
.error { color: var(--red); font-size: 12px; margin-top: 6px; }
```

Also set `app/index.html` `<title>RiskGuard Console</title>`.

- [ ] **Step 2: Create app/src/components/TopBar.tsx**

```tsx
import { useState } from "react";
import { ConnectButton } from "@mysten/dapp-kit-react/ui";
import { MARKETS } from "../config";
import { useOracle, useCaps, useExecute } from "../hooks/useChain";
import { buildPause } from "../lib/tx";
import { PKG } from "../config";
import { gate } from "../lib/caps";

function OracleLight() {
  const o = useOracle(MARKETS[0]);
  if (!o.data) return <span className="dim">ORACLE …</span>;
  return (
    <span className="dim">
      ORACLE {o.data.active ? <span className="status-ok">● ACTIVE</span> : <span className="status-bad">⏸ PAUSED</span>}
    </span>
  );
}

/** Spec §3: one-click pause from anywhere. Single market for now → pauses it
 * directly; with >1 market this becomes a market-picker popover. */
export function TopBar() {
  const { caps } = useCaps();
  const execute = useExecute();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const g = gate(caps.emergencyCapId, "EmergencyStopCap");

  const onPause = async () => {
    setBusy(true); setErr(null);
    try {
      await execute(buildPause(PKG, MARKETS[0].oracleId, caps.emergencyCapId!));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <header className="topbar">
      <span className="brand">⬡ RISKGUARD</span>
      <OracleLight />
      <button className="btn btn-danger" disabled={!g.enabled || busy} title={g.tooltip ?? ""} onClick={onPause}>
        {busy ? "PAUSING…" : "⏸ EMERGENCY PAUSE"}
      </button>
      {err && <span className="error">{err}</span>}
      <span className="spacer" />
      <span className="dim">testnet</span>
      <ConnectButton />
    </header>
  );
}
```

- [ ] **Step 3: Create app/src/components/Sidebar.tsx**

```tsx
export type Page = "markets" | "emergency" | "override" | "upgrades";
const PAGES: { id: Page; label: string }[] = [
  { id: "markets", label: "📊 Markets" },
  { id: "emergency", label: "🚨 Emergency" },
  { id: "override", label: "🛡 Override" },
  { id: "upgrades", label: "⏱ Upgrades" },
];

export function Sidebar({ page, onNavigate }: { page: Page; onNavigate: (p: Page) => void }) {
  return (
    <nav className="sidebar">
      {PAGES.map((p) => (
        <button key={p.id} className={`nav-item${page === p.id ? " active" : ""}`} onClick={() => onNavigate(p.id)}>
          {p.label}
        </button>
      ))}
    </nav>
  );
}
```

- [ ] **Step 4: Create app/src/components/EventTicker.tsx**

```tsx
import { useEvents } from "../hooks/useChain";

const COLOR: Record<string, string> = {
  OverrideApplied: "status-warn", ActionReverted: "status-warn",
  OraclePaused: "status-bad", OracleResumed: "status-ok",
};

export function EventTicker() {
  const events = useEvents();
  return (
    <footer className="ticker">
      <span style={{ color: "var(--cyan-soft)" }}>EVENT STREAM ▸</span>
      {(events.data ?? []).slice(0, 20).map((e) => (
        <span key={e.key}>
          {new Date(e.tsMs).toLocaleTimeString()}{" "}
          <span className={COLOR[e.name] ?? ""}>{e.name}</span>{" "}
          <span className="dim">{JSON.stringify(e.json)}</span>
        </span>
      ))}
    </footer>
  );
}
```

- [ ] **Step 5: Replace app/src/App.tsx**

```tsx
import { useState } from "react";
import { TopBar } from "./components/TopBar";
import { Sidebar, type Page } from "./components/Sidebar";
import { EventTicker } from "./components/EventTicker";
import { MarketsPage } from "./components/MarketsPage";
import { EmergencyPage } from "./components/EmergencyPage";
import { OverridePage } from "./components/OverridePage";
import { UpgradesPage } from "./components/UpgradesPage";

export default function App() {
  const [page, setPage] = useState<Page>("markets");
  return (
    <div className="app">
      <TopBar />
      <div className="main">
        <Sidebar page={page} onNavigate={setPage} />
        <main className="page">
          {page === "markets" && <MarketsPage />}
          {page === "emergency" && <EmergencyPage />}
          {page === "override" && <OverridePage />}
          {page === "upgrades" && <UpgradesPage />}
        </main>
      </div>
      <EventTicker />
    </div>
  );
}
```

Create four placeholder pages so this compiles (each replaced by Tasks 9-12) — e.g. `app/src/components/MarketsPage.tsx`:

```tsx
export function MarketsPage() { return <p className="dim">Markets — coming in Task 9</p>; }
```

Same pattern for `EmergencyPage.tsx`, `OverridePage.tsx`, `UpgradesPage.tsx` (adjust name/text).

- [ ] **Step 6: Verify it renders**

```bash
cd app && pnpm exec tsc --noEmit && pnpm dev
```

Open http://localhost:5173 — expect Tron shell: grid background, topbar with ConnectButton + oracle light (live testnet read), sidebar, ticker showing real events from the Task 0 deploy.

- [ ] **Step 7: Commit**

```bash
git add app/src/theme.css app/src/components app/src/App.tsx app/index.html
git commit -m "feat(app): Tron theme + console shell (topbar/sidebar/ticker)"
```

---

### Task 9: Markets page — card/list toggle + market card

**Files:**
- Create: `app/src/components/MarketCard.tsx`
- Modify: `app/src/components/MarketsPage.tsx`

- [ ] **Step 1: Create app/src/components/MarketCard.tsx**

```tsx
import type { MarketConfig } from "../config";
import { usePolicy, useOracle } from "../hooks/useChain";
import { FLAG_LABELS } from "../lib/monotonic";

export function MarketCard({ market, onOpen }: { market: MarketConfig; onOpen: (m: MarketConfig) => void }) {
  const policy = usePolicy(market);
  const oracle = useOracle(market);
  if (policy.isPending || oracle.isPending) return <div className="card dim">loading {market.label}…</div>;
  if (policy.error || oracle.error) return <div className="card status-bad">{market.label}: read failed</div>;
  const p = policy.data!, o = oracle.data!;
  const staleS = o.latestScoreTsMs ? Math.round((Date.now() - o.latestScoreTsMs) / 1000) : null;
  const activeFlags = FLAG_LABELS.filter((f) => (p.flags & f.bit) !== 0);

  return (
    <div className="card" onClick={() => onOpen(market)}>
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <h3>{market.label}</h3>
        {o.active ? <span className="status-ok">● ACTIVE</span> : <span className="status-bad">⏸ PAUSED</span>}
      </div>
      <div className="metric">{p.ltvBps}<span className="dim"> bps LTV</span></div>
      <div className="dim">
        SCORE {o.latestScoreBps} · STALE {staleS === null ? "—" : `${staleS}s`} · PENDING{" "}
        <span className={p.pending.length > 0 ? "status-warn" : ""}>{p.pending.length}</span>
      </div>
      {activeFlags.length > 0 && (
        <div className="status-warn" style={{ fontSize: 11, marginTop: 6 }}>
          ⚑ {activeFlags.map((f) => f.label).join(" · ")}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Replace app/src/components/MarketsPage.tsx**

```tsx
import { useState } from "react";
import { MARKETS, type MarketConfig } from "../config";
import { MarketCard } from "./MarketCard";
import { MarketDrawer } from "./MarketDrawer";

export function MarketsPage() {
  const [view, setView] = useState<"grid" | "list">("grid");
  const [open, setOpen] = useState<MarketConfig | null>(null);
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 14 }}>
        <h2 style={{ margin: 0, color: "var(--cyan)", fontSize: 16 }}>MARKETS</h2>
        <span>
          <button className="btn" style={{ opacity: view === "grid" ? 1 : 0.5 }} onClick={() => setView("grid")}>▦ grid</button>{" "}
          <button className="btn" style={{ opacity: view === "list" ? 1 : 0.5 }} onClick={() => setView("list")}>☰ list</button>
        </span>
      </div>
      <div className={view === "grid" ? "grid-cards" : "list-rows"}>
        {MARKETS.map((m) => <MarketCard key={m.policyId} market={m} onOpen={setOpen} />)}
      </div>
      {open && <MarketDrawer market={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
```

Create a compiling stub `app/src/components/MarketDrawer.tsx` (replaced in Task 10):

```tsx
import type { MarketConfig } from "../config";
export function MarketDrawer({ market, onClose }: { market: MarketConfig; onClose: () => void }) {
  return <aside className="drawer"><button className="btn" onClick={onClose}>✕</button><p className="dim">{market.label} — Task 10</p></aside>;
}
```

- [ ] **Step 3: Verify**

Run: `cd app && pnpm exec tsc --noEmit && pnpm dev` — Markets page shows the SUI/USD card with live values; grid/list toggle works; click opens stub drawer.

- [ ] **Step 4: Commit**

```bash
git add app/src/components/MarketCard.tsx app/src/components/MarketsPage.tsx app/src/components/MarketDrawer.tsx
git commit -m "feat(app): markets page with card/list toggle"
```

---

### Task 10: Market drawer — status, pending+revert, pause/resume, force protect

**Files:**
- Create: `app/src/components/ForceProtectForm.tsx`
- Modify: `app/src/components/MarketDrawer.tsx`

- [ ] **Step 1: Create app/src/components/ForceProtectForm.tsx**

```tsx
import { useState } from "react";
import type { MarketConfig } from "../config";
import { PKG } from "../config";
import type { PolicyState } from "../lib/parsers";
import { validateForceProtect, FLAG_LABELS, KNOWN_FLAGS } from "../lib/monotonic";
import { buildForceProtect } from "../lib/tx";
import { useCaps, useExecute } from "../hooks/useChain";
import { gate } from "../lib/caps";

export function ForceProtectForm({ market, policy }: { market: MarketConfig; policy: PolicyState }) {
  const { caps } = useCaps();
  const execute = useExecute();
  const capId = caps.overrideCapIds[market.marketType] ?? null;
  const g = gate(capId, `OverrideCap<${market.label}>`);

  const [ltv, setLtv] = useState(String(policy.ltvBps));
  const [flags, setFlags] = useState(policy.flags & KNOWN_FLAGS);
  const [reason, setReason] = useState("0");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const ltvNum = Number(ltv);
  const v = validateForceProtect({ ltvBps: policy.ltvBps, flags: policy.flags }, ltvNum, flags);
  const reasonNum = Number(reason);
  const reasonOk = Number.isInteger(reasonNum) && reasonNum >= 0 && reasonNum <= 255;

  const submit = async () => {
    setBusy(true); setMsg(null);
    try {
      const digest = await execute(buildForceProtect(PKG, market.policyId, capId!, market.marketType,
        { newLtvBps: ltvNum, newFlags: flags, reasonCode: reasonNum }));
      setMsg(`✓ OverrideApplied — ${digest.slice(0, 10)}…`);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section style={{ marginTop: 16 }}>
      <h3 style={{ color: "var(--orange)", fontSize: 13 }}>🛡 FORCE PROTECT</h3>
      <label className="dim">new LTV (bps, ≤ {policy.ltvBps}) </label>
      <input className="input" value={ltv} onChange={(e) => setLtv(e.target.value)} style={{ width: 90 }} />
      <div style={{ margin: "8px 0" }}>
        {FLAG_LABELS.map((f) => (
          <label key={f.bit} className="dim" style={{ display: "block" }}>
            <input
              type="checkbox"
              checked={(flags & f.bit) !== 0}
              disabled={(policy.flags & f.bit) !== 0} // already set on-chain: cannot clear (monotonic)
              onChange={(e) => setFlags(e.target.checked ? flags | f.bit : flags & ~f.bit)}
            /> {f.label}{(policy.flags & f.bit) !== 0 ? " (on-chain)" : ""}
          </label>
        ))}
      </div>
      <label className="dim">reason code (0-255) </label>
      <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: 60 }} />
      <div style={{ marginTop: 10 }}>
        <button
          className="btn btn-danger"
          disabled={!g.enabled || !v.ok || !reasonOk || busy}
          title={g.tooltip ?? (v.ok ? "" : v.reason)}
          onClick={submit}
        >
          {busy ? "EXECUTING…" : "FORCE PROTECT"}
        </button>
      </div>
      {!v.ok && <div className="error">{v.reason}</div>}
      {!reasonOk && <div className="error">reason code must be an integer 0-255</div>}
      {msg && <div className={msg.startsWith("✓") ? "status-ok" : "error"} style={{ fontSize: 12, marginTop: 6 }}>{msg}</div>}
    </section>
  );
}
```

- [ ] **Step 2: Replace app/src/components/MarketDrawer.tsx**

```tsx
import { useState } from "react";
import type { MarketConfig } from "../config";
import { PKG } from "../config";
import { usePolicy, useOracle, useCaps, useExecute } from "../hooks/useChain";
import { buildPause, buildResume, buildRevert } from "../lib/tx";
import { gate } from "../lib/caps";
import { ForceProtectForm } from "./ForceProtectForm";
import { FLAG_LABELS } from "../lib/monotonic";

const KIND = ["?", "FLAG_SET", "LTV", "OVERRIDE"]; // kind 3 = KIND_OVERRIDE

export function MarketDrawer({ market, onClose }: { market: MarketConfig; onClose: () => void }) {
  const policy = usePolicy(market);
  const oracle = useOracle(market);
  const { caps } = useCaps();
  const execute = useExecute();
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const run = async (label: string, tx: Parameters<typeof execute>[0]) => {
    setBusy(label); setErr(null);
    try { await execute(tx); } catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(null); }
  };

  if (!policy.data || !oracle.data) {
    return <aside className="drawer"><button className="btn" onClick={onClose}>✕</button><p className="dim">loading…</p></aside>;
  }
  const p = policy.data, o = oracle.data;
  const overrideCapId = caps.overrideCapIds[market.marketType] ?? null;
  const gOverride = gate(overrideCapId, `OverrideCap<${market.label}>`);
  const gPause = gate(caps.emergencyCapId, "EmergencyStopCap");
  const gResume = gate(caps.adminCapId, "AdminCap");
  const now = Date.now();

  return (
    <aside className="drawer">
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <h3 style={{ color: "var(--cyan)" }}>{market.label}</h3>
        <button className="btn" onClick={onClose}>✕</button>
      </div>
      <div className="metric">{p.ltvBps}<span className="dim"> bps LTV (default {p.ltvDefaultBps})</span></div>
      <div className="dim">score {o.latestScoreBps} · nonce {o.nonce} · max_staleness {o.maxStalenessMs}ms</div>
      <div style={{ margin: "8px 0" }}>
        {FLAG_LABELS.map((f) => (
          <span key={f.bit} className={(p.flags & f.bit) !== 0 ? "status-warn" : "dim"} style={{ marginRight: 10, fontSize: 11 }}>
            {(p.flags & f.bit) !== 0 ? "⚑" : "·"} {f.label}
          </span>
        ))}
      </div>

      <section>
        {o.active ? (
          <button className="btn btn-danger" disabled={!gPause.enabled || busy !== null} title={gPause.tooltip ?? ""}
            onClick={() => run("pause", buildPause(PKG, market.oracleId, caps.emergencyCapId!))}>
            {busy === "pause" ? "…" : "⏸ PAUSE ORACLE"}
          </button>
        ) : (
          <button className="btn" disabled={!gResume.enabled || busy !== null} title={gResume.tooltip ?? ""}
            onClick={() => run("resume", buildResume(PKG, market.oracleId, caps.adminCapId!))}>
            {busy === "resume" ? "…" : "▶ RESUME ORACLE"}
          </button>
        )}
      </section>

      <section style={{ marginTop: 16 }}>
        <h3 style={{ color: "var(--cyan-soft)", fontSize: 13 }}>PENDING ACTIONS ({p.pending.length}/8)</h3>
        {p.pending.length === 0 && <p className="dim">none</p>}
        {p.pending.map((a) => {
          const remainMs = a.tsMs + p.revertWindowMs - now;
          const revertable = remainMs > 0;
          return (
            <div key={a.actionId} style={{ borderTop: "1px dashed var(--border-dim)", padding: "6px 0", fontSize: 11 }}>
              <span className="status-warn">#{a.actionId}</span> {KIND[a.kind] ?? a.kind} · prev ltv {a.prevLtvBps} · reason {a.reasonCode}
              <div className="dim">
                {revertable ? `revertable ${Math.ceil(remainMs / 60000)}m more` : "window closed"}{" "}
                <button className="btn" style={{ fontSize: 10, padding: "2px 8px" }}
                  disabled={!gOverride.enabled || !revertable || busy !== null}
                  title={gOverride.tooltip ?? (revertable ? "" : "revert window closed")}
                  onClick={() => run(`revert-${a.actionId}`, buildRevert(PKG, market.policyId, overrideCapId!, market.marketType, a.actionId))}>
                  {busy === `revert-${a.actionId}` ? "…" : "REVERT"}
                </button>
              </div>
            </div>
          );
        })}
      </section>

      <ForceProtectForm market={market} policy={p} />
      <MarketEvents market={market} />
      {err && <div className="error">{err}</div>}
    </aside>
  );
}
```

And append to the same file (spec §6: per-market event filter inside the drawer; matching is by-content because not every event carries a `market` field):

```tsx
import { useEvents } from "../hooks/useChain"; // add to the imports at top

function MarketEvents({ market }: { market: MarketConfig }) {
  const events = useEvents();
  const mine = (events.data ?? []).filter((e) => {
    const s = JSON.stringify(e.json);
    return s.includes(market.marketType) || s.includes(market.policyId) || s.includes(market.oracleId);
  });
  return (
    <section style={{ marginTop: 16 }}>
      <h3 style={{ color: "var(--cyan-soft)", fontSize: 13 }}>MARKET EVENTS</h3>
      {mine.length === 0 && <p className="dim">none</p>}
      {mine.slice(0, 10).map((e) => (
        <div key={e.key} className="dim" style={{ fontSize: 11, padding: "3px 0" }}>
          {new Date(e.tsMs).toLocaleTimeString()} <span className="status-warn">{e.name}</span>
        </div>
      ))}
    </section>
  );
}
```

- [ ] **Step 3: Verify**

`cd app && pnpm exec tsc --noEmit && pnpm dev` — drawer opens with live state; without caps in the connected wallet all action buttons are disabled with tooltips; with the deployer wallet (holds all caps from Task 0) buttons enable.

- [ ] **Step 4: Commit**

```bash
git add app/src/components/MarketDrawer.tsx app/src/components/ForceProtectForm.tsx
git commit -m "feat(app): market drawer with pause/resume, revert, force-protect"
```

---

### Task 11: Emergency + Override pages (cross-market overview + history)

**Files:**
- Modify: `app/src/components/EmergencyPage.tsx`, `app/src/components/OverridePage.tsx`

- [ ] **Step 1: Replace EmergencyPage.tsx**

```tsx
import { MARKETS } from "../config";
import { useOracle, useEvents } from "../hooks/useChain";

function Row({ market }: { market: (typeof MARKETS)[number] }) {
  const o = useOracle(market);
  return (
    <div className="card" style={{ cursor: "default", marginBottom: 8 }}>
      <h3>{market.label}</h3>
      {o.data
        ? o.data.active ? <span className="status-ok">● ACTIVE</span> : <span className="status-bad">⏸ PAUSED</span>
        : <span className="dim">…</span>}
      <p className="dim" style={{ marginTop: 6 }}>
        Pause = EmergencyStopCap (single-sig, instant). Resume = AdminCap (slow path). Use the market drawer to act.
      </p>
    </div>
  );
}

export function EmergencyPage() {
  const events = useEvents();
  const history = (events.data ?? []).filter((e) => e.name === "OraclePaused" || e.name === "OracleResumed");
  return (
    <div>
      <h2 style={{ margin: "0 0 14px", color: "var(--cyan)", fontSize: 16 }}>🚨 EMERGENCY</h2>
      {MARKETS.map((m) => <Row key={m.oracleId} market={m} />)}
      <h3 style={{ color: "var(--cyan-soft)", fontSize: 13 }}>HISTORY</h3>
      {history.length === 0 && <p className="dim">no pause/resume events</p>}
      {history.map((e) => (
        <div key={e.key} className="dim" style={{ fontSize: 11, padding: "4px 0" }}>
          {new Date(e.tsMs).toLocaleString()} <span className={e.name === "OraclePaused" ? "status-bad" : "status-ok"}>{e.name}</span> {JSON.stringify(e.json)}
        </div>
      ))}
    </div>
  );
}
```

- [ ] **Step 2: Replace OverridePage.tsx**

```tsx
import { useEvents } from "../hooks/useChain";

export function OverridePage() {
  const events = useEvents();
  const history = (events.data ?? []).filter((e) => e.name === "OverrideApplied" || e.name === "ActionReverted");
  return (
    <div>
      <h2 style={{ margin: "0 0 14px", color: "var(--cyan)", fontSize: 16 }}>🛡 OVERRIDE</h2>
      <p className="dim">
        force_protect is monotonic-protective: it may only LOWER the LTV cap or ADD pause flags
        (bypasses oracle gates + loosen rate-limit). Apply it from a market drawer. Overrides share the
        snapshot stack, so a panic-tighten can itself be reverted within the revert window.
      </p>
      <h3 style={{ color: "var(--cyan-soft)", fontSize: 13 }}>HISTORY</h3>
      {history.length === 0 && <p className="dim">no override/revert events</p>}
      {history.map((e) => (
        <div key={e.key} className="dim" style={{ fontSize: 11, padding: "4px 0" }}>
          {new Date(e.tsMs).toLocaleString()} <span className="status-warn">{e.name}</span> {JSON.stringify(e.json)}
        </div>
      ))}
    </div>
  );
}
```

- [ ] **Step 3: Verify + commit**

```bash
cd app && pnpm exec tsc --noEmit
git add app/src/components/EmergencyPage.tsx app/src/components/OverridePage.tsx
git commit -m "feat(app): emergency + override overview/history pages"
```

---

### Task 12: Upgrades page — timelock countdown + propose/cancel

**Files:**
- Modify: `app/src/components/UpgradesPage.tsx`

- [ ] **Step 1: Replace UpgradesPage.tsx**

```tsx
import { useEffect, useState } from "react";
import { PKG, REGISTRY_ID } from "../config";
import { useRegistry, useCaps, useExecute } from "../hooks/useChain";
import { buildProposeUpgrade, buildCancelUpgrade } from "../lib/tx";
import { gate } from "../lib/caps";

function hexToBytes(hex: string): number[] | null {
  const h = hex.replace(/^0x/, "");
  if (h.length !== 64 || /[^0-9a-fA-F]/.test(h)) return null; // digest must be 32 bytes
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(i * 2, i * 2 + 2), 16));
}

function Countdown({ readyAtMs }: { readyAtMs: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  const remain = readyAtMs - now;
  if (remain <= 0) return <span className="status-ok">⏱ TIMELOCK ELAPSED — executable</span>;
  const h = Math.floor(remain / 3_600_000), m = Math.floor((remain % 3_600_000) / 60_000), s = Math.floor((remain % 60_000) / 1000);
  return (
    <span className="status-warn" style={{ fontSize: 22, textShadow: "0 0 10px rgba(255,107,53,.6)" }}>
      ⏱ {h}h {m}m {s}s
    </span>
  );
}

export function UpgradesPage() {
  const reg = useRegistry();
  const { caps } = useCaps();
  const execute = useExecute();
  const gAdmin = gate(caps.adminCapId, "AdminCap");
  const [digest, setDigest] = useState("");
  const [policy, setPolicy] = useState("0");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  if (!reg.data) return <p className="dim">loading registry…</p>;
  const r = reg.data;
  const digestBytes = hexToBytes(digest);
  const policyNum = Number(policy);
  const policyOk = [0, 128, 192].includes(policyNum); // COMPATIBLE / ADDITIVE / DEP_ONLY

  const run = async (label: string, fn: () => ReturnType<typeof buildProposeUpgrade>) => {
    setBusy(true); setMsg(null);
    try { await execute(fn()); setMsg(`✓ ${label} ok`); }
    catch (e) { setMsg(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };

  return (
    <div>
      <h2 style={{ margin: "0 0 14px", color: "var(--cyan)", fontSize: 16 }}>⏱ UPGRADES</h2>
      <div className="card" style={{ cursor: "default", marginBottom: 14 }}>
        <span className="dim">cap version <b style={{ color: "#fff" }}>{r.capVersion}</b> · epoch {r.epoch} · timelock {r.timelockMs / 3_600_000}h</span>
      </div>

      {r.pending ? (
        <div className="card" style={{ cursor: "default", borderColor: "var(--orange)" }}>
          <h3 style={{ color: "var(--orange)" }}>PENDING UPGRADE (epoch {r.pending.epoch})</h3>
          <div style={{ margin: "10px 0" }}><Countdown readyAtMs={r.pending.proposedAtMs + r.timelockMs} /></div>
          <div className="dim" style={{ fontSize: 11 }}>
            digest 0x{r.pending.digest.map((b) => b.toString(16).padStart(2, "0")).join("")} · policy {r.pending.policy}
          </div>
          <div style={{ marginTop: 10, display: "flex", gap: 8 }}>
            <button className="btn btn-danger" disabled={!gAdmin.enabled || busy} title={gAdmin.tooltip ?? ""}
              onClick={() => run("cancel", () => buildCancelUpgrade(PKG, REGISTRY_ID, caps.adminCapId!))}>
              CANCEL
            </button>
          </div>
          <p className="dim" style={{ fontSize: 11, marginTop: 10 }}>
            Execute is permissionless once the timelock elapses, but needs the upgrade bytecode —
            run from CLI in the same PTB (hot-potato): <br />
            <code>execute_upgrade → tx.upgrade(modules, deps) → commit_upgrade</code> — see ts/ scripts.
          </p>
        </div>
      ) : (
        <div className="card" style={{ cursor: "default" }}>
          <h3>PROPOSE (AdminCap, starts 72h timelock)</h3>
          <label className="dim">digest (0x + 64 hex) </label>
          <input className="input" value={digest} onChange={(e) => setDigest(e.target.value)} style={{ width: 320 }} />
          <label className="dim" style={{ marginLeft: 10 }}>policy </label>
          <select className="input" value={policy} onChange={(e) => setPolicy(e.target.value)}>
            <option value="0">0 COMPATIBLE</option>
            <option value="128">128 ADDITIVE</option>
            <option value="192">192 DEP_ONLY</option>
          </select>
          <div style={{ marginTop: 10 }}>
            <button className="btn" disabled={!gAdmin.enabled || !digestBytes || !policyOk || busy}
              title={gAdmin.tooltip ?? (!digestBytes ? "digest must be 32 bytes hex" : "")}
              onClick={() => run("propose", () => buildProposeUpgrade(PKG, REGISTRY_ID, caps.adminCapId!, digestBytes!, policyNum))}>
              {busy ? "…" : "PROPOSE UPGRADE"}
            </button>
          </div>
          {!digestBytes && digest.length > 0 && <div className="error">digest must be 0x + exactly 64 hex chars</div>}
        </div>
      )}
      {msg && <div className={msg.startsWith("✓") ? "status-ok" : "error"} style={{ marginTop: 8, fontSize: 12 }}>{msg}</div>}
    </div>
  );
}
```

- [ ] **Step 2: Verify + commit**

```bash
cd app && pnpm exec tsc --noEmit
git add app/src/components/UpgradesPage.tsx
git commit -m "feat(app): upgrades page with 72h timelock countdown + propose/cancel"
```

---

### Task 13: Full verification — tests, build, live walkthrough, monkey testing

**Files:**
- Modify: `tasks/progress.md`, `move-notes.md` (notes only)

- [ ] **Step 1: Full unit suite + build**

```bash
cd app && pnpm test && pnpm exec tsc --noEmit && pnpm build
```

Expected: all vitest suites pass (abortCodes, monotonic, parsers, caps, tx); production build succeeds.

- [ ] **Step 2: Live manual walkthrough (testnet, deployer wallet = holds all caps)**

`pnpm dev`, connect the deployer wallet, then verify in order:

1. Markets card shows live LTV/score/pending; grid↔list toggle.
2. Drawer: pause oracle → topbar light flips to PAUSED + `OraclePaused` hits ticker. Resume (AdminCap) → flips back.
3. Force protect: lower LTV by 500 bps → success message; pending count +1; `OverrideApplied` in ticker; Override page history shows it.
4. Revert the override from the drawer → LTV restored; `ActionReverted` in ticker.
5. Upgrades: propose digest `0x` + 64 hex chars (e.g. all `aa`), policy 0 → countdown appears at ~72h; cancel → returns to propose form.
6. Disconnect, connect a fresh cap-less wallet → ALL action buttons disabled with tooltips naming the missing cap.

- [ ] **Step 3: Monkey testing（per .claude/rules/test.md — 把它玩壞）**

In the running app, try to break it; every case must fail gracefully (no blank screen, no unhandled rejection in console):

- Force-protect LTV inputs: `99999`, `-5`, `3.7`, `abc`, empty, paste of 1000 chars → submit stays disabled with reason.
- Reason code: `256`, `-1`, `1e3` → disabled.
- Upgrade digest: `0x123`, 63 hex chars, 65 hex chars, unicode → disabled with error.
- Double-click every action button rapidly → busy-state prevents double submission.
- Reject the wallet prompt mid-transaction → error shown, app keeps working.
- Kill the network (devtools offline) → queries error states render, no crash; restore → recovers.
- Open drawer, let an action's revert window expire while open → REVERT disables on next poll/render.

- [ ] **Step 4: Update notes + progress**

Append to `move-notes.md` and `tasks/progress.md`: app/ structure, new `.deployed.json` schema (8 ids), SDK split decision (dapp-kit 2.x writes / JSON-RPC reads, queryEvents removed in SDK v2), walkthrough + monkey results, known limitations (event polling latency; upgrade execute via CLI only).

- [ ] **Step 5: Commit**

```bash
git add tasks/progress.md move-notes.md
git commit -m "docs: DAO console verified (unit + live walkthrough + monkey testing)"
```

---

## Review follow-up (after all tasks)

Per project skill-routing: frontend dApp review = `sui-frontend` review + generic reviewer 輔助 (this is TS/React, not Move — generic reviewer allowed as assistant). No `move-code-quality`/`sui-red-team` needed (zero Move changes).
