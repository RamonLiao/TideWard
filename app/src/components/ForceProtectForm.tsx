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
