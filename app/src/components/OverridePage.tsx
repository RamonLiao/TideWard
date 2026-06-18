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
