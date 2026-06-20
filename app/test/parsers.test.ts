import { describe, it, expect } from "vitest";
import { parsePolicy, parseOracle, parseRegistry, parseEvent, eventMatchesMarket, formatEvent } from "../src/lib/parsers";

const policyFields = {
  ltv_bps: 4000, ltv_default_bps: 5000, flags: 1,
  revert_window_ms: "60000", min_loosen_interval_ms: "3600000",
  last_loosen_ts_ms: "0", max_conf_bps: 500, oracle_id: "0xabc",
  next_action_id: "3",
  pending_actions: [
    { type: "0xPKG::policy::ActionSnapshot", fields: {
      action_id: "2", kind: 1, prev_ltv_bps: 5000, prev_flags: 0, reason_code: 9, ts_ms: "1718000000000" } },
  ],
  reserved: [],
};

describe("parsePolicy", () => {
  it("converts u64 strings to numbers and unwraps nested snapshots", () => {
    const p = parsePolicy(policyFields as never);
    expect(p.ltvBps).toBe(4000);
    expect(p.revertWindowMs).toBe(60000);
    expect(p.pending).toHaveLength(1);
    expect(p.pending[0]).toMatchObject({ actionId: 2, kind: 1, prevLtvBps: 5000, tsMs: 1718000000000 });
  });
  it("accepts FLAT nested snapshots too (gRPC shape tolerance)", () => {
    const flat = { ...policyFields, pending_actions: [
      { action_id: "2", kind: 1, prev_ltv_bps: 5000, prev_flags: 0, reason_code: 9, ts_ms: "1718000000000" },
    ] };
    expect(parsePolicy(flat as never).pending[0].actionId).toBe(2);
  });
  it("throws loudly on a foreign/empty record instead of returning garbage", () => {
    expect(() => parsePolicy({} as never)).toThrow(/RiskPolicy/i);
  });
});

describe("parseOracle", () => {
  it("reads active/nonce/staleness", () => {
    const o = parseOracle({
      active: true, latest_score_bps: 7777, latest_score_ts_ms: "1718000000000",
      nonce: "5", max_staleness_ms: "60000", expected_feed_id: [1, 2],
    } as never);
    expect(o).toMatchObject({ active: true, latestScoreBps: 7777, nonce: 5, maxStalenessMs: 60000 });
  });
});

describe("parseRegistry", () => {
  it("handles no pending (Option none)", () => {
    const r = parseRegistry({
      timelock_ms: "259200000", epoch: "1", pending: null,
      cap: { type: "0x2::package::UpgradeCap", fields: { version: "1", policy: 0 } },
    } as never);
    expect(r.pending).toBeNull();
    expect(r.capVersion).toBe(1);
  });
  it("handles a pending proposal (Option some), flat or wrapped", () => {
    const r = parseRegistry({
      timelock_ms: "259200000", epoch: "2",
      pending: { type: "0xPKG::upgrade_registry::PendingUpgrade", fields: {
        digest: [1], policy: 0, proposed_at_ms: "1718000000000", epoch: "2" } },
      cap: { version: "1", policy: 0 },
    } as never);
    expect(r.pending).toMatchObject({ proposedAtMs: 1718000000000, policy: 0 });
  });
  // Live-only regression: gRPC core.getObject json serializes vector<u8> as a
  // base64 STRING, not number[]. UpgradesPage does `pending.digest.map(...)`, so
  // a string digest crashed the page ("digest.map is not a function"). parseRegistry
  // must normalize every transport form to number[] or the live propose path breaks.
  it("normalizes a base64-string digest (gRPC json) to number[]", () => {
    const r = parseRegistry({
      timelock_ms: "259200000", epoch: "0",
      pending: { digest: "AQIetw==", policy: 0, proposed_at_ms: "1718000000000", epoch: "0" },
      cap: { version: "1", policy: 0 },
    } as never);
    expect(r.pending!.digest).toEqual([1, 2, 30, 183]);
  });
  it("normalizes a 0x-hex digest to number[]", () => {
    const r = parseRegistry({
      timelock_ms: "259200000", epoch: "0",
      pending: { digest: "0x01021eb7", policy: 128, proposed_at_ms: "1", epoch: "0" },
      cap: { version: "1", policy: 0 },
    } as never);
    expect(r.pending!.digest).toEqual([1, 2, 30, 183]);
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
    expect(e.txDigest).toBe("D"); // drives the explorer deep-link on click
  });
});

describe("formatEvent", () => {
  const mk = (name: string, json: Record<string, unknown>) =>
    formatEvent({ key: "k", name, tsMs: 0, json });
  const market = { name: "0000000000000000000000000000000000000000000000000000000000000002::sui::SUI" };
  const addr = "0xbdecf8a2fd1db5dfd049830a4ff5da5836d250b938a1e81f46157fdbdc3ee01f";

  it("renders OverrideApplied as a plain sentence with coin symbol + short addr", () => {
    const s = mk("OverrideApplied", { action_id: "0", market, prev_ltv: 5000, new_ltv: 4000, prev_flags: 0, new_flags: 0, reason_code: 7, by: addr });
    expect(s).toBe("🛡 Override #0 · SUI LTV 5000→4000bps · reason 7 · by 0xbdec…e01f");
  });
  it("renders UpgradeCancelled with a truncated digest (array form)", () => {
    const s = mk("UpgradeCancelled", { digest: Array(32).fill(17), epoch: "1", by: addr });
    expect(s).toBe("Upgrade cancelled · epoch 1 · digest 0x1111…1111 · by 0xbdec…e01f");
  });
  // The ticker must never silently drop an event type we forgot to handle.
  it("falls back to raw JSON for unknown event names", () => {
    expect(mk("SomethingNew", { x: 1 })).toBe('{"x":1}');
  });
});

describe("eventMatchesMarket", () => {
  const market = { marketType: "0x2::sui::SUI", policyId: "0xpol", oracleId: "0xora" };
  it("matches OverrideApplied carrying only the full-padded TypeName (regression)", () => {
    // OverrideApplied has no policy/oracle id, only the market TypeName, which the
    // chain serializes full-padded without 0x. Short-form includes() alone misses it.
    const json = { action_id: "0", market: { name: "0000000000000000000000000000000000000000000000000000000000000002::sui::SUI" } };
    expect(eventMatchesMarket(json, market)).toBe(true);
  });
  it("matches events carrying the oracle/policy id", () => {
    expect(eventMatchesMarket({ oracle: "0xora" }, market)).toBe(true);
    expect(eventMatchesMarket({ policy_id: "0xpol" }, market)).toBe(true);
  });
  it("rejects an unrelated market's event", () => {
    const other = { market: { name: "000000000000000000000000000000000000000000000000000000000000dead::coin::FOO" } };
    expect(eventMatchesMarket(other, market)).toBe(false);
  });
});
