// Move object fields → typed domain objects. Transport-agnostic: callers
// (hooks) extract the fields record from their client's response shape.
// u64 arrives as string, u8/u16 as number; nested structs may be wrapped
// ({type, fields}) by JSON-RPC or flat in other transports — unwrap() handles both.

/* eslint-disable @typescript-eslint/no-explicit-any */

const n = (v: string | number): number => Number(v);

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
      ? { digest: p.digest as number[], policy: n(p.policy),
          proposedAtMs: n(p.proposed_at_ms), epoch: n(p.epoch) }
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
