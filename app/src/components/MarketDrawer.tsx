import { useState } from "react";
import type { MarketConfig } from "../config";
import { PKG } from "../config";
import { usePolicy, useOracle, useCaps, useExecute, useEvents } from "../hooks/useChain";
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
