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
