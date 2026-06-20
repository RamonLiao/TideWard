import { useState } from "react";
import { TopBar } from "./components/TopBar";
import { Sidebar, type Page } from "./components/Sidebar";
import { EventTicker } from "./components/EventTicker";
import { MarketsPage } from "./components/MarketsPage";
import { EmergencyPage } from "./components/EmergencyPage";
import { OverridePage } from "./components/OverridePage";
import { UpgradesPage } from "./components/UpgradesPage";
import { DocsPage } from "./components/DocsPage";

export default function App() {
  const [page, setPage] = useState<Page>("markets");
  return (
    <div className="app">
      <TopBar />
      <div className="main">
        <Sidebar page={page} onNavigate={setPage} />
        <main className="page">
          {page === "markets" && <MarketsPage />}
          {page === "emergency" && <EmergencyPage />}
          {page === "override" && <OverridePage />}
          {page === "upgrades" && <UpgradesPage />}
          {page === "docs" && <DocsPage />}
        </main>
      </div>
      <EventTicker />
    </div>
  );
}
