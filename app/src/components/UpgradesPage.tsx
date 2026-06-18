import { useEffect, useState } from "react";
import { PKG, REGISTRY_ID } from "../config";
import { useRegistry, useCaps, useExecute } from "../hooks/useChain";
import { buildProposeUpgrade, buildCancelUpgrade } from "../lib/tx";
import { gate } from "../lib/caps";

function hexToBytes(hex: string): number[] | null {
  const h = hex.replace(/^0x/, "");
  if (h.length !== 64 || /[^0-9a-fA-F]/.test(h)) return null; // digest must be 32 bytes
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(i * 2, i * 2 + 2), 16));
}

function Countdown({ readyAtMs }: { readyAtMs: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  const remain = readyAtMs - now;
  if (remain <= 0) return <span className="status-ok">⏱ TIMELOCK ELAPSED — executable</span>;
  const h = Math.floor(remain / 3_600_000), m = Math.floor((remain % 3_600_000) / 60_000), s = Math.floor((remain % 60_000) / 1000);
  return (
    <span className="status-warn" style={{ fontSize: 22, textShadow: "0 0 10px rgba(255,107,53,.6)" }}>
      ⏱ {h}h {m}m {s}s
    </span>
  );
}

export function UpgradesPage() {
  const reg = useRegistry();
  const { caps } = useCaps();
  const execute = useExecute();
  const gAdmin = gate(caps.adminCapId, "AdminCap");
  const [digest, setDigest] = useState("");
  const [policy, setPolicy] = useState("0");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  if (!reg.data) return <p className="dim">loading registry…</p>;
  const r = reg.data;
  const digestBytes = hexToBytes(digest);
  const policyNum = Number(policy);
  const policyOk = [0, 128, 192].includes(policyNum); // COMPATIBLE / ADDITIVE / DEP_ONLY

  const run = async (label: string, fn: () => ReturnType<typeof buildProposeUpgrade>) => {
    setBusy(true); setMsg(null);
    try { await execute(fn()); setMsg(`✓ ${label} ok`); }
    catch (e) { setMsg(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };

  return (
    <div>
      <h2 style={{ margin: "0 0 14px", color: "var(--cyan)", fontSize: 16 }}>⏱ UPGRADES</h2>
      <div className="card" style={{ cursor: "default", marginBottom: 14 }}>
        <span className="dim">cap version <b style={{ color: "#fff" }}>{r.capVersion}</b> · epoch {r.epoch} · timelock {r.timelockMs / 3_600_000}h</span>
      </div>

      {r.pending ? (
        <div className="card" style={{ cursor: "default", borderColor: "var(--orange)" }}>
          <h3 style={{ color: "var(--orange)" }}>PENDING UPGRADE (epoch {r.pending.epoch})</h3>
          <div style={{ margin: "10px 0" }}><Countdown readyAtMs={r.pending.proposedAtMs + r.timelockMs} /></div>
          <div className="dim" style={{ fontSize: 11 }}>
            digest 0x{r.pending.digest.map((b) => b.toString(16).padStart(2, "0")).join("")} · policy {r.pending.policy}
          </div>
          <div style={{ marginTop: 10, display: "flex", gap: 8 }}>
            <button className="btn btn-danger" disabled={!gAdmin.enabled || busy} title={gAdmin.tooltip ?? ""}
              onClick={() => run("cancel", () => buildCancelUpgrade(PKG, REGISTRY_ID, caps.adminCapId!))}>
              CANCEL
            </button>
          </div>
          <p className="dim" style={{ fontSize: 11, marginTop: 10 }}>
            Execute is permissionless once the timelock elapses, but needs the upgrade bytecode —
            run from CLI in the same PTB (hot-potato): <br />
            <code>execute_upgrade → tx.upgrade(modules, deps) → commit_upgrade</code> — see ts/ scripts.
          </p>
        </div>
      ) : (
        <div className="card" style={{ cursor: "default" }}>
          <h3>PROPOSE (AdminCap, starts 72h timelock)</h3>
          <label className="dim">digest (0x + 64 hex) </label>
          <input className="input" value={digest} onChange={(e) => setDigest(e.target.value)} style={{ width: 320 }} />
          <label className="dim" style={{ marginLeft: 10 }}>policy </label>
          <select className="input" value={policy} onChange={(e) => setPolicy(e.target.value)}>
            <option value="0">0 COMPATIBLE</option>
            <option value="128">128 ADDITIVE</option>
            <option value="192">192 DEP_ONLY</option>
          </select>
          <div style={{ marginTop: 10 }}>
            <button className="btn" disabled={!gAdmin.enabled || !digestBytes || !policyOk || busy}
              title={gAdmin.tooltip ?? (!digestBytes ? "digest must be 32 bytes hex" : "")}
              onClick={() => run("propose", () => buildProposeUpgrade(PKG, REGISTRY_ID, caps.adminCapId!, digestBytes!, policyNum))}>
              {busy ? "…" : "PROPOSE UPGRADE"}
            </button>
          </div>
          {!digestBytes && digest.length > 0 && <div className="error">digest must be 0x + exactly 64 hex chars</div>}
        </div>
      )}
      {msg && <div className={msg.startsWith("✓") ? "status-ok" : "error"} style={{ marginTop: 8, fontSize: 12 }}>{msg}</div>}
    </div>
  );
}
