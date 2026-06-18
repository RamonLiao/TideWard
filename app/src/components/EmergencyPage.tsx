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
