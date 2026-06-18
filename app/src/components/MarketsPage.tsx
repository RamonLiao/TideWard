import { useState } from "react";
import { MARKETS, type MarketConfig } from "../config";
import { MarketCard } from "./MarketCard";
import { MarketDrawer } from "./MarketDrawer";

export function MarketsPage() {
  const [view, setView] = useState<"grid" | "list">("grid");
  const [open, setOpen] = useState<MarketConfig | null>(null);
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 14 }}>
        <h2 style={{ margin: 0, color: "var(--cyan)", fontSize: 16 }}>MARKETS</h2>
        <span>
          <button className="btn" style={{ opacity: view === "grid" ? 1 : 0.5 }} onClick={() => setView("grid")}>▦ grid</button>{" "}
          <button className="btn" style={{ opacity: view === "list" ? 1 : 0.5 }} onClick={() => setView("list")}>☰ list</button>
        </span>
      </div>
      <div className={view === "grid" ? "grid-cards" : "list-rows"}>
        {MARKETS.map((m) => <MarketCard key={m.policyId} market={m} onOpen={setOpen} />)}
      </div>
      {open && <MarketDrawer market={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
