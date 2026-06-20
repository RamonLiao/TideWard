// Static usage guide. Plain-language by design (a 12-year-old should follow it),
// but every on-chain fact here mirrors the contracts: monotonic-protective override,
// asymmetric pause/resume caps, 60s revert window (this testnet deploy), 72h upgrade timelock.

const card: React.CSSProperties = {
  border: "1px solid var(--border)",
  background: "var(--panel)",
  borderRadius: 8,
  padding: "16px 18px",
  marginBottom: 14,
};
const h3: React.CSSProperties = { color: "var(--cyan)", fontSize: 14, margin: "0 0 8px" };
const kbd: React.CSSProperties = {
  fontFamily: "var(--font-mono)",
  background: "var(--code-bg)",
  border: "1px solid var(--border-dim)",
  borderRadius: 4,
  padding: "1px 6px",
  fontSize: 12,
  color: "var(--cyan-soft)",
};

function Term({ word, children }: { word: string; children: React.ReactNode }) {
  return (
    <div style={{ display: "flex", gap: 10, padding: "5px 0", borderTop: "1px dashed var(--border-dim)" }}>
      <span style={{ minWidth: 130, color: "var(--orange)", fontWeight: 600 }}>{word}</span>
      <span className="dim" style={{ fontSize: 13, lineHeight: 1.5 }}>{children}</span>
    </div>
  );
}

const REASON_CODES = [
  ["0", "No reason given / routine"],
  ["1", "Oracle price looks wrong (big deviation)"],
  ["2", "Asset lost its peg (de-peg)"],
  ["3", "Suspicious on-chain activity"],
  ["7", "Manual drill / testing"],
  ["…", "Any number 0–255 your team agrees on"],
];

export function DocsPage() {
  return (
    <div style={{ maxWidth: 760 }}>
      <h2 style={{ margin: "0 0 6px", color: "var(--cyan)", fontSize: 16 }}>📖 DOCS — HOW TO USE RISKGUARD</h2>
      <p className="dim" style={{ fontSize: 13, marginBottom: 18 }}>
        RiskGuard is a <b>safety dashboard for a lending market</b>. Think of a lending market like a
        machine that lets people borrow money against the crypto they put in. If something scary
        happens (a price goes crazy, a hack), an operator can hit the brakes here — and every brake
        press is written to the blockchain so nobody can do it secretly.
      </p>

      <div style={card}>
        <h3 style={h3}>1 · GET STARTED (3 steps)</h3>
        <ol className="dim" style={{ fontSize: 13, lineHeight: 1.7, paddingLeft: 18, margin: 0 }}>
          <li>Click <span style={kbd}>Connect Wallet</span> (top-right) and pick your Sui wallet.</li>
          <li>Make sure the wallet is on <b>testnet</b> (this is a practice network — not real money).</li>
          <li>You can only press a button if your wallet holds the matching <b>key</b> (see §5).
            No key → the button is greyed out. Hover it to see which key is missing.</li>
        </ol>
      </div>

      <div style={card}>
        <h3 style={h3}>2 · THE FOUR TABS</h3>
        <Term word="📊 Markets">The list of markets. Click a card to open its control panel (the drawer on the right).</Term>
        <Term word="🚨 Emergency">The big red button: freeze (pause) the whole oracle so no new risk scores can be posted.</Term>
        <Term word="🛡 Override">A history log of every "force protect" and "revert" that ever happened.</Term>
        <Term word="⏱ Upgrades">Proposals to upgrade the smart contract. These have a <b>72-hour waiting timer</b> so everyone can see it coming.</Term>
      </div>

      <div style={card}>
        <h3 style={h3}>3 · WHAT THE BUTTONS DO</h3>
        <Term word="⏸ Pause Oracle">
          Hit the brakes. Stops new risk scores from being accepted. Use it when something looks wrong.
        </Term>
        <Term word="▶ Resume Oracle">
          Take the brakes off. On purpose, pausing and un-pausing need <b>different keys</b> — so the person
          who can panic-stop isn't automatically the person who can turn it back on.
        </Term>
        <Term word="🛡 Force Protect">
          Make the market <b>safer right now</b>, without waiting for the price oracle. You may only
          tighten — lower the borrow limit (LTV) or switch on a "paused" flag. You can <b>never</b> use it
          to loosen rules. The chain rejects a no-op (a change that changes nothing) with error code 24.
        </Term>
        <Term word="REVERT">
          Undo one specific Force Protect — but only inside the <b>revert window</b> (this practice deploy: 60 seconds).
          After that the button locks and the change becomes permanent until a new action replaces it.
        </Term>
      </div>

      <div style={card}>
        <h3 style={h3}>4 · WORDS YOU'LL SEE</h3>
        <Term word="LTV (bps)">
          "Loan-to-Value" = how much you may borrow vs. what you put in. Measured in <b>bps</b>
          (basis points): <span style={kbd}>4000 bps = 40%</span>. Lower = safer.
        </Term>
        <Term word="Flags">
          On/off switches that pause one activity: borrows, liquidations, deposits, or withdraws.
          Force Protect can turn them ON but not OFF (that would be loosening).
        </Term>
        <Term word="Pending Actions (n/8)">
          Recent Force Protects that can still be reverted. Max 8 at a time. Each shows a live countdown.
        </Term>
        <Term word="Reason code">
          A number 0–255 you attach to a Force Protect to record <b>why</b> you did it. The contract does
          not check it — it's a note for auditors. Your team decides what each number means (see §6).
        </Term>
        <Term word="Score / Nonce / Staleness">
          Score = the latest risk reading. Nonce = a counter that blocks replays (old messages can't be re-used).
          Staleness = how old a price is allowed to be before it's rejected.
        </Term>
        <Term word="72h Timelock">
          Contract upgrades can't happen instantly. Anyone proposing one starts a 72-hour clock — visible to
          all — so users have time to react before the new code goes live.
        </Term>
      </div>

      <div style={card}>
        <h3 style={h3}>5 · KEYS (CAPABILITIES) — WHO CAN PRESS WHAT</h3>
        <p className="dim" style={{ fontSize: 13, marginTop: 0 }}>
          On Sui, permission is an object you <b>hold in your wallet</b>, called a capability ("cap").
          One cap = one job. There is only one of each, so two people can't use the same cap at once.
        </p>
        <Term word="AdminCap">Resume the oracle. Propose / cancel upgrades.</Term>
        <Term word="EmergencyStopCap">Pause the oracle (the panic button).</Term>
        <Term word="OverrideCap&lt;M&gt;">Force Protect and Revert for one market <b>M</b>.</Term>
        <Term word="PublisherCap">Post risk scores (used by the off-chain risk engine, not these buttons).</Term>
      </div>

      <div style={card}>
        <h3 style={h3}>6 · REASON CODE CHEAT-SHEET (example convention)</h3>
        <p className="dim" style={{ fontSize: 12, marginTop: 0 }}>
          These meanings are <b>not enforced on-chain</b> — they're a suggested team convention. Pick your own.
        </p>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <tbody>
            {REASON_CODES.map(([code, meaning]) => (
              <tr key={code} style={{ borderTop: "1px dashed var(--border-dim)" }}>
                <td style={{ padding: "5px 0", width: 60 }}><span style={kbd}>{code}</span></td>
                <td className="dim" style={{ padding: "5px 0" }}>{meaning}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div style={{ ...card, borderColor: "var(--orange)" }}>
        <h3 style={{ ...h3, color: "var(--orange)" }}>⚠ REMEMBER</h3>
        <ul className="dim" style={{ fontSize: 13, lineHeight: 1.7, paddingLeft: 18, margin: 0 }}>
          <li>This is <b>testnet</b> — practice money, safe to experiment.</li>
          <li>Force Protect can only make things <b>safer</b>, never riskier.</li>
          <li>Want to undo a Force Protect? Do it <b>fast</b> — the revert window is short.</li>
          <li>Every action is public on the blockchain. There are no secret moves.</li>
        </ul>
      </div>
    </div>
  );
}
