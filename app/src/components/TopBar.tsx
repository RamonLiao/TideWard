import { useState } from "react";
import { ConnectButton } from "@mysten/dapp-kit-react/ui";
import { MARKETS } from "../config";
import { useOracle, useCaps, useExecute } from "../hooks/useChain";
import { buildPause } from "../lib/tx";
import { PKG } from "../config";
import { gate } from "../lib/caps";

function OracleLight() {
  const o = useOracle(MARKETS[0]);
  if (!o.data) return <span className="dim">ORACLE …</span>;
  return (
    <span className="dim">
      ORACLE {o.data.active ? <span className="status-ok">● ACTIVE</span> : <span className="status-bad">⏸ PAUSED</span>}
    </span>
  );
}

/** Spec §3: one-click pause from anywhere. Single market for now → pauses it
 * directly; with >1 market this becomes a market-picker popover. */
export function TopBar() {
  const { caps } = useCaps();
  const execute = useExecute();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const g = gate(caps.emergencyCapId, "EmergencyStopCap");

  const onPause = async () => {
    setBusy(true); setErr(null);
    try {
      await execute(buildPause(PKG, MARKETS[0].oracleId, caps.emergencyCapId!));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <header className="topbar">
      <span className="brand">⬡ RISKGUARD</span>
      <OracleLight />
      <button className="btn btn-danger" disabled={!g.enabled || busy} title={g.tooltip ?? ""} onClick={onPause}>
        {busy ? "PAUSING…" : "⏸ EMERGENCY PAUSE"}
      </button>
      {err && <span className="error">{err}</span>}
      <span className="spacer" />
      <span className="dim">testnet</span>
      <ConnectButton />
    </header>
  );
}
