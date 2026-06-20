export type Page = "markets" | "emergency" | "override" | "upgrades" | "docs";
const PAGES: { id: Page; label: string }[] = [
  { id: "markets", label: "📊 Markets" },
  { id: "emergency", label: "🚨 Emergency" },
  { id: "override", label: "🛡 Override" },
  { id: "upgrades", label: "⏱ Upgrades" },
  { id: "docs", label: "📖 Docs" },
];

export function Sidebar({ page, onNavigate }: { page: Page; onNavigate: (p: Page) => void }) {
  return (
    <nav className="sidebar">
      {PAGES.map((p) => (
        <button key={p.id} className={`nav-item${page === p.id ? " active" : ""}`} onClick={() => onNavigate(p.id)}>
          {p.label}
        </button>
      ))}
    </nav>
  );
}
