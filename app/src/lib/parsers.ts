// Move object fields → typed domain objects. Transport-agnostic: callers
// (hooks) extract the fields record from their client's response shape.
// u64 arrives as string, u8/u16 as number; nested structs may be wrapped
// ({type, fields}) by JSON-RPC or flat in other transports — unwrap() handles both.

/* eslint-disable @typescript-eslint/no-explicit-any */

import { normalizeStructTag, fromBase64, fromHex } from "@mysten/sui/utils";

const n = (v: string | number): number => Number(v);

/** A Move `vector<u8>` reaches us in different shapes per transport: a number[]
 * (JSON-RPC / mock), a base64 string (gRPC `core.getObject` json), or a 0x-hex
 * string. Normalize to number[] so renderers can `.map` safely. The live
 * upgrade-digest crash (UpgradesPage `digest.map is not a function`) was this:
 * gRPC returned base64 but parseRegistry cast it `as number[]`. */
export function toBytes(v: unknown): number[] {
  if (Array.isArray(v)) return v.map((x) => Number(x) & 0xff);
  if (typeof v === "string") {
    if (v.startsWith("0x")) return Array.from(fromHex(v));
    try { return Array.from(fromBase64(v)); }
    catch { return Array.from(fromHex(v)); }
  }
  return [];
}

/** Tolerates both `{type, fields: {...}}` wrappers and flat records. */
const unwrap = (s: any): Record<string, any> => (s && typeof s === "object" && "fields" in s ? s.fields : s);

function expectField(f: Record<string, any>, key: string, what: string): void {
  if (!(key in f)) throw new Error(`${what}: missing field '${key}' — wrong object or transport shape changed`);
}

export interface PendingAction {
  actionId: number; kind: number; prevLtvBps: number;
  prevFlags: number; reasonCode: number; tsMs: number;
}
export interface PolicyState {
  ltvBps: number; ltvDefaultBps: number; flags: number;
  revertWindowMs: number; minLoosenIntervalMs: number; lastLoosenTsMs: number;
  maxConfBps: number; oracleId: string; pending: PendingAction[];
}

export function parsePolicy(f: Record<string, any>): PolicyState {
  expectField(f, "ltv_bps", "RiskPolicy");
  return {
    ltvBps: n(f.ltv_bps), ltvDefaultBps: n(f.ltv_default_bps), flags: n(f.flags),
    revertWindowMs: n(f.revert_window_ms), minLoosenIntervalMs: n(f.min_loosen_interval_ms),
    lastLoosenTsMs: n(f.last_loosen_ts_ms), maxConfBps: n(f.max_conf_bps),
    oracleId: String(f.oracle_id),
    pending: (f.pending_actions as any[]).map(unwrap).map((s) => ({
      actionId: n(s.action_id), kind: n(s.kind),
      prevLtvBps: n(s.prev_ltv_bps), prevFlags: n(s.prev_flags),
      reasonCode: n(s.reason_code), tsMs: n(s.ts_ms),
    })),
  };
}

export interface OracleState {
  active: boolean; latestScoreBps: number; latestScoreTsMs: number;
  nonce: number; maxStalenessMs: number;
}

export function parseOracle(f: Record<string, any>): OracleState {
  expectField(f, "active", "RiskOracle");
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

export function parseRegistry(f: Record<string, any>): RegistryState {
  expectField(f, "timelock_ms", "UpgradeRegistry");
  const p = f.pending ? unwrap(f.pending) : null;
  return {
    timelockMs: n(f.timelock_ms), epoch: n(f.epoch),
    capVersion: n(unwrap(f.cap).version),
    pending: p
      ? { digest: toBytes(p.digest), policy: n(p.policy),
          proposedAtMs: n(p.proposed_at_ms), epoch: n(p.epoch) }
      : null,
  };
}

export interface ChainEvent {
  key: string; name: string; tsMs: number; json: Record<string, unknown>; txDigest: string;
}

export function parseEvent(raw: { id: { txDigest: string; eventSeq: string }; type: string; parsedJson: Record<string, unknown>; timestampMs?: string }): ChainEvent {
  return {
    key: `${raw.id.txDigest}:${raw.id.eventSeq}`,
    txDigest: raw.id.txDigest,
    name: raw.type.split("::").pop() ?? raw.type,
    tsMs: raw.timestampMs ? Number(raw.timestampMs) : 0,
    json: raw.parsedJson,
  };
}

// === Human-readable event formatting (for the ticker) =======================
// The raw parsedJson is unreadable in a marquee (full-padded TypeNames, 32-byte
// digest arrays, addresses). Turn each event into one short plain-language line.

const shortAddr = (a: unknown): string => {
  const s = String(a ?? "");
  return s.length > 12 ? `${s.slice(0, 6)}…${s.slice(-4)}` : s;
};

/** Phantom market TypeName ("000…002::sui::SUI" or "0x2::sui::SUI") → coin symbol. */
const marketLabel = (m: unknown): string => {
  const name = (m && typeof m === "object" && "name" in m ? (m as any).name : m) ?? "";
  const seg = String(name).split("::").pop();
  return seg || String(name);
};

/** digest as number[] | base64 | hex → "0xabcd…1234". */
const digestLabel = (d: unknown): string => {
  const bytes = toBytes(d);
  if (!bytes.length) return "0x?";
  const hex = bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
  return hex.length > 12 ? `0x${hex.slice(0, 4)}…${hex.slice(-4)}` : `0x${hex}`;
};

const UPGRADE_POLICY: Record<number, string> = { 0: "COMPATIBLE", 128: "ADDITIVE", 192: "DEP_ONLY" };

/** One concise human-readable line for a chain event. Falls back to the raw JSON
 * for any event type we don't special-case, so nothing is silently dropped. */
export function formatEvent(e: ChainEvent): string {
  const j = e.json as Record<string, any>;
  switch (e.name) {
    case "ScorePosted":
      return `Score posted · ${marketLabel(j.market)} ${n(j.score_bps)}bps · nonce ${n(j.nonce)}`;
    case "ActionExecuted":
      return `Action #${n(j.action_id)} · ${marketLabel(j.market)} LTV ${n(j.prev_ltv)}→${n(j.new_ltv)}bps · score ${n(j.score_bps)}`;
    case "ActionReverted":
      return `Action #${n(j.action_id)} reverted · ${marketLabel(j.market)} · by ${shortAddr(j.by)}`;
    case "OraclePaused":
      return `⏸ Oracle paused · by ${shortAddr(j.by)}`;
    case "OracleResumed":
      return `▶ Oracle resumed · by ${shortAddr(j.by)}`;
    case "MarketRegistered":
      return `Market registered · ${marketLabel(j.market)}`;
    case "UpgradeProposed":
      return `Upgrade proposed · epoch ${n(j.epoch)} · ${UPGRADE_POLICY[n(j.policy)] ?? `policy ${n(j.policy)}`} · digest ${digestLabel(j.digest)} · ETA ${new Date(n(j.eta_ms)).toLocaleString()}`;
    case "UpgradeCancelled":
      return `Upgrade cancelled · epoch ${n(j.epoch)} · digest ${digestLabel(j.digest)} · by ${shortAddr(j.by)}`;
    case "UpgradeExecuted":
      return `Upgrade executed · epoch ${n(j.epoch)} · digest ${digestLabel(j.digest)}`;
    case "OverrideApplied":
      return `🛡 Override #${n(j.action_id)} · ${marketLabel(j.market)} LTV ${n(j.prev_ltv)}→${n(j.new_ltv)}bps · reason ${n(j.reason_code)} · by ${shortAddr(j.by)}`;
    default:
      return JSON.stringify(j);
  }
}

/** True when a package event belongs to the given market. Matches on policy/oracle
 * id OR the phantom market TypeName. The TypeName is serialized full-padded WITHOUT
 * a 0x prefix (e.g. 000…002::sui::SUI), while config uses short form (0x2::sui::SUI) —
 * OverrideApplied carries only the TypeName, so we must compare the canonical no-0x
 * form too or those events get filtered out of the per-market list. */
export function eventMatchesMarket(
  json: Record<string, unknown>,
  market: { marketType: string; policyId: string; oracleId: string },
): boolean {
  const s = JSON.stringify(json);
  const typeNo0x = normalizeStructTag(market.marketType).replace(/^0x/, "");
  return (
    s.includes(market.policyId) ||
    s.includes(market.oracleId) ||
    s.includes(market.marketType) ||
    s.includes(typeNo0x)
  );
}
