import { useEvents } from "../hooks/useChain";
import { formatEvent, type ChainEvent } from "../lib/parsers";
import { explorerTxUrl } from "../config";

const COLOR: Record<string, string> = {
  OverrideApplied: "status-warn", ActionReverted: "status-warn",
  OraclePaused: "status-bad", OracleResumed: "status-ok",
  UpgradeProposed: "status-warn", UpgradeCancelled: "status-bad", UpgradeExecuted: "status-ok",
  MarketRegistered: "status-ok",
};

function Item({ e }: { e: ChainEvent }) {
  return (
    <a
      className="ticker-item"
      href={explorerTxUrl(e.txDigest)}
      target="_blank"
      rel="noopener noreferrer"
      title="Open transaction in explorer ↗"
    >
      <span className="dim">{new Date(e.tsMs).toLocaleTimeString()}</span>{" "}
      <span className={COLOR[e.name] ?? ""}>{formatEvent(e)}</span>
    </a>
  );
}

export function EventTicker() {
  const events = useEvents();
  const items = (events.data ?? []).slice(0, 20);
  return (
    <footer className="ticker">
      <span className="ticker-label">EVENT STREAM ▸</span>
      {items.length === 0 ? (
        <span className="dim">waiting for events…</span>
      ) : (
        // Duplicate the list so the marquee loops seamlessly (the animation
        // translates by -50%, landing the 2nd copy exactly where the 1st began).
        // Pause on hover so a reader can stop and read a line.
        <div className="ticker-track">
          {[0, 1].map((dup) => (
            <div className="ticker-run" key={dup} aria-hidden={dup === 1}>
              {items.map((e) => <Item key={`${dup}:${e.key}`} e={e} />)}
            </div>
          ))}
        </div>
      )}
    </footer>
  );
}
