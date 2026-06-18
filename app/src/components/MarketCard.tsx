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
