# RiskGuard — Business Specification

> Sui Overflow 2026, Track 0 Agentic Web, Sub-track 1 (Autonomous Risk Guardian).
> One-liner: **Autonomous AI risk guardian SaaS for Sui lending/perp protocols** — Pyth ingest → AI risk score → Move policy object autonomously bumps LTV / pauses market via PTB → on-chain log → DAO override.

---

## 1. Executive Summary

- DeFi lenders still run on **static LTV, hard-coded oracle prices, and human governance** that reacts in hours; markets de-peg in seconds. 2025-2026 saw **$285M Stream/Euler bad debt (Nov 2025)**, **$19.3B liquidation cascade (Oct 10 2025)**, and **~$230M rsETH/Aave hit (Apr 2026)** — all rooted in static risk parameters or oracle hardcoding ([Zircuit](https://www.zircuit.com/blog/the-lessons-of-failure-terra-celsius-and-stream-finance), [CCN](https://www.ccn.com/news/crypto/19-billion-liquidation-analysis-2025/), [Aave Gov](https://governance.aave.com/t/rseth-incident-report-april-20-2026/24580)).
- Incumbents (Hypernative, Chaos Labs, Gauntlet) own EVM but **have no native Sui product**, while Sui DeFi crossed **~$2.6B TVL** with Suilend ($745M) + Navi ($723M) + Momentum ($551M) as concentrated systemic targets ([DefiLlama Sui](https://defillama.com/chain/Sui)).
- RiskGuard ships a **Move policy object** that is the on-chain enforcement primitive — risk decisions are not advisory webhooks, they are atomic PTBs the protocol cannot ignore but the DAO can revert.
- B2B SaaS: protocols pay $5-25k/month per market. Day-one design partner = one Sui lender + Pyth + Bluefin (perp) for demo credibility.
- Hackathon demo: live Pyth feed → simulated SUI de-peg → AI score crosses threshold → autonomous LTV cut on devnet fork → DAO multisig reverts in front of judges.

---

## 2. Problem Statement

Lending and perp protocols on every chain rely on three brittle assumptions: (a) oracle prices are honest and continuous, (b) LTV/IR parameters set by governance last for weeks, (c) humans can react in time. All three failed repeatedly in 2025-2026.

**Concrete evidence:**

| Date | Protocol | Loss | Root cause |
|---|---|---|---|
| 2025-01-10 | Usual / Morpho | ~$7.5M | Static LTV vs USD0++ redemption repeg to $0.87 ([Blockworks](https://blockworks.co/news/usual-protocol-depeg-spurs-instability-in-defi-markets)) |
| 2025-10-10 | Compound / market-wide | $19.3B liquidations | Oracle deviation 35% on USDe/wBETH during flash crash ([CCN](https://www.ccn.com/news/crypto/19-billion-liquidation-analysis-2025/)) |
| 2025-11-04 | Stream / Euler | $285M bad debt | xUSD hardcoded at $1, real price $0.07 ([Zircuit](https://www.zircuit.com/blog/the-lessons-of-failure-terra-celsius-and-stream-finance)) |
| 2025-12-20 | Aave V3 | $27M wrongful liquidations | CAPO oracle misconfig on wstETH ([Aave forum](https://governance.aave.com/t/capo-incident-post-mortem/23000)) |
| 2026-04-18 | Aave / Kelp | $123-230M | rsETH bridge exploit + static LTV ([Aave Gov](https://governance.aave.com/t/rseth-incident-report-april-20-2026/24580)) |
| 2026-04 | Scallop (Sui) | undisclosed | Reward pool incident, capital outflow ([Scallop Medium](https://medium.com/scallop-io)) |

**Pattern:** a parameter-failure incident hits a major lending protocol every 2-3 months. The shared root cause is the **gap between off-chain risk insight and on-chain enforcement** — insights live in Discord, dashboards, or Gauntlet PDFs; enforcement requires a multi-day DAO vote.

On Sui specifically the gap is worse: as of 2026-05, no Sui-native autonomous risk-enforcement agent has shipped. The closest coverage is monitoring-only: Hypernative provides sequencer-layer firewall/threat detection for Sui protocols, Chaos Labs runs a real-time risk portal for Bluefin perps, and Scallop maintains an in-house parameter engine scoped to its own pools — none expose a policy object that other Sui lenders can import for atomic on-chain enforcement (gemini scan 2026-05, cross-checked against [DefiLlama Sui](https://defillama.com/chain/Sui)). Meanwhile the top three lenders sit on $2B+ TVL with the same oracle (Pyth) — a single bad price update is a correlated failure.

---

## 3. Target Users & Personas

### Persona A — "Sara, Head of Risk @ a Sui Lending Protocol" (primary buyer)
- 5-person team, ex-TradFi quant.
- JTBD: keep bad-debt ratio < 0.5%, satisfy institutional LP audits, sleep through Asia-hours volatility.
- Currently uses: hand-rolled Python dashboards, Telegram alerts, governance forum posts.
- Will pay: yes — line item under "security & risk", precedent set by Aave paying Chaos Labs / Gauntlet 6-7 figures annually ([Chaos Labs proposals](https://governance.aave.com/)).

### Persona B — "Marcus, Treasury Lead @ a Crypto-Native Fund" (LP / amplifier)
- $50-200M deployed across Sui yield strategies.
- JTBD: avoid waking up to a 20% drawdown from a Sui de-peg; have an audit trail to show the GP.
- Will not pay directly but **demands** RiskGuard coverage from protocols he LPs into — same dynamic as institutional LPs pushing for Chaos Labs coverage on EVM.

### Persona C — "Aria, Sui DAO multisig signer" (governance override)
- Cares about: not getting rugged by a rogue AI; clear revert path; transparent on-chain log.
- JTBD: trust-but-verify — see every autonomous action with a one-click revert.

---

## 4. Use Cases / Scenarios

### Scenario 1 — Stablecoin de-peg (the Stream/xUSD replay)
Pyth feed shows BUCK (Sui native stablecoin, [Bucket](https://bucketprotocol.io)) trading at $0.94 across DEX TWAPs. RiskGuard's scorer flags depeg-risk = 0.82. Move policy object autonomously: (1) caps BUCK collateral LTV from 85% → 50%, (2) pauses new BUCK borrows, (3) emits `RiskActionExecuted` event. Bad debt prevented. DAO can revert within 24h via 3-of-5 multisig.

### Scenario 2 — Oracle deviation guard (the CAPO replay)
Pyth wstETH price diverges from Switchboard secondary feed by 4.1%. Scorer trips circuit-breaker rule. Policy object halts liquidations on that market for 15 minutes (Move object timestamp). DAO reviews, either extends pause or auto-resumes.

### Scenario 3 — Perp funding-rate runaway on Bluefin
Bluefin perp open interest concentration on SUI-PERP crosses 70% one-sided + funding rate accelerates. RiskGuard raises maintenance margin from 5% → 8% via policy object, surfacing the rationale ("funding > 0.1%/hr for 3 windows, OI skew 72%") to the dashboard. Traders see the alert before forced ADL hits them.

### Scenario 4 — Institutional LP reporting
Marcus's quarterly LP report auto-includes a RiskGuard PDF: every autonomous action, the AI score time-series, DAO overrides, and the comparison vs the "would-have-happened-without-RiskGuard" counterfactual. This is the line item that closes the SaaS contract.

---

## 5. Market Analysis

### Sizing
- **TAM (DeFi risk + on-chain security tooling, order-of-magnitude estimate from publicly-cited report summaries)**: Blockchain Security ~$3.0B (2024) → $4.97B (2025), MarketsandMarkets CAGR ~65.5% to 2029 ([M&M summary](https://www.marketsandmarkets.com/Market-Reports/blockchain-security-market-100222014.html)); DeFi data/analytics ~$3.5B → $4.82B and crypto insurance ~$6.4B → $9.49B per Grand View Research summaries ([GVR DeFi](https://www.grandviewresearch.com/industry-analysis/decentralized-finance-market-report)); blockchain risk & compliance infra ~$1.45B → $1.80B ([MarketIntelo](https://marketintelo.com/report/blockchain-risk-and-compliance-infrastructure-market/)). Aggregated adjacent TAM ≈ $14-15B (2024) → $21B (2025) — narrower and lower than the prior $30-61B figure, which conflated broader DeFi market sizing. Primary reports paywalled; treat as order-of-magnitude only.
- **SAM (protocol-paid risk SaaS)**: $6-7.5B 2024 → $8-10.5B 2025.
- **SOM (Sui-native, year 1)**: 8-12 Sui DeFi protocols × $60-300k ACV ≈ **$1-3M ARR realistic ceiling** for first 12 months.

Sui DeFi as of 2026-05: ~**$2.6B TVL**, top lenders Suilend $745M, Navi $723M, Momentum $551M, Bluefin perp $105M ([DefiLlama Sui](https://defillama.com/chain/Sui)).

### Competitive landscape

| Competitor | Wedge | Sui-native? | Pricing | Funding |
|---|---|---|---|---|
| Hypernative ([hypernative.io](https://www.hypernative.io)) | Real-time threat detection, "Guardian" pre-execution sim | Live on Sui: Guardian wallet pre-sign sim + Firewall at sequencer layer, 250+ Sui protocols integrated incl. PancakeSwap Sui [source: Sui Live Miami Keynote, May 2026; Hypernative blog 2026] | Enterprise SaaS, ~$5-30k/mo | $40M Series B 2025 (Ten Eleven) |
| Chaos Labs ([chaoslabs.xyz](https://www.chaoslabs.xyz)) | Economic risk simulation, Chaos AI researcher | No | DAO-paid, % of TVL or fixed | $55M Series A 2024 (Haun) |
| Gauntlet ([gauntlet.xyz](https://www.gauntlet.xyz)) | Quant risk management, retainer | No | 6-7 figure annual retainers | $23.8M Series B 2022, $1B val |
| Forta ([forta.org](https://www.forta.org)) | Decentralized monitoring net, Firewall 2.0 | No | Free + FORT-token paid feeds | $23M Series B 2021 (a16z) |
| Spotter ([spotter.pessimistic.io](https://spotter.pessimistic.io)) | Circuit breakers, dev tool | No | Project / monthly | Seed |
| Ironblocks ([ironblocks.com](https://www.ironblocks.com)) | Contract firewall | No | Free entry + enterprise | $7M seed 2023 |

**Critical insight from research:** every serious incumbent is EVM-first and has not shipped a Sui product. The Sui Foundation's own Hypernative announcement (Sui ↔ Hypernative co-marketing) suggests demand, but a **Sui-native, Move-policy-object-enforced** competitor is currently absent. RiskGuard's window is **12-18 months** before Chaos Labs ports.

---

## 6. Differentiation — Why Sui-native matters

1. **Enforcement, not alerts.** Incumbents on EVM send webhooks; protocols still need a multisig to act. On Sui, RiskGuard's risk decisions are **Move policy objects passed into the lender's PTB** — the lending Move module *must* consult the policy object, by import. Risk action = single atomic PTB, no governance lag.
2. **Object-level granularity.** Sui's object model lets RiskGuard scope a policy per market (e.g., `Policy<BUCK-USDC>`) instead of per-protocol globals. Granular blast radius, granular revert.
3. **Composable PTBs.** A single RiskGuard PTB can simultaneously: read Pyth, update policy object, pause market, notify DAO multisig — atomic, gasless to compose, deterministic ordering. EVM equivalents are 3-4 txs and a race condition.
4. **DAO override as a first-class capability.** Sui's `Capability` pattern + multisig-owned `OverrideCap` makes "revert any RiskGuard action within N hours" a 1-line check in Move. EVM patterns rely on Timelock contracts that are 5-10x more code.
5. **Seal for confidential parameters.** RiskGuard's proprietary risk weights can be Seal-encrypted on-chain ([Seal](https://blog.sui.io/seal-key-management/)), readable only by the policy object's decryption keys at execution time. Incumbents leak their model weights via inference. (Seal integration is design-stage in v1.)

---

## 7. Product Scope

### MVP (hackathon, 4 weeks)
- Live Pyth price subscription for 3 assets (SUI, USDC, BUCK).
- Rule-based + lightweight ML scorer (logistic regression on volatility, oracle deviation, liquidity drain). Off-chain, but score posted on-chain every block where it changes.
- One `RiskPolicy` Move object (caps LTV, per-market pause flag).
- One autonomous action: LTV cut on a devnet fork of a Sui lender.
- DAO override = 2-of-3 multisig that emits `RevertPolicy` event.
- Dashboard: live score, last 10 actions, override button.

### v1 (post-hackathon, 3 months → testnet partner)
- Switchboard secondary oracle for deviation guard.
- Backtest engine: replay Stream/Euler/Usual incidents against Sui markets.
- Multi-protocol policy objects (Suilend + Navi + Bluefin perp).
- Audit-grade event log + PDF export for institutional LPs.

### v2 (6-12 months → mainnet)
- Seal-encrypted risk weights.
- Per-protocol customizable rules engine.
- Insurance partnership (Nexus Mutual style) using RiskGuard score as underwriting input.
- Cross-protocol contagion model (e.g., Suilend BUCK depeg → Navi liquidation cascade prediction).

---

## 8. User Flow (Persona A — Sara onboarding)

1. Sara visits riskguard.xyz, books call → 14-day pilot agreement.
2. Her protocol's Move team adds `riskguard::policy::assert_action_allowed(...)` to their lending entry functions (1-line gate).
3. Sara picks markets to cover, sets thresholds (e.g., "pause if oracle deviation > 3% for 60s").
4. RiskGuard provisions a `RiskPolicy` object owned by a multisig: 2 RiskGuard signers + 3 protocol-DAO signers (DAO majority).
5. Sara watches dashboard. Pyth flashes a BUCK de-peg. AI score climbs to 0.84. Policy object autonomously caps LTV.
6. Sara gets Telegram alert with the PTB digest + rationale. DAO has 24h to revert; Slack thread pings governance.
7. End of month, PDF report auto-generated, sent to LPs.

---

## 9. Technical Architecture (summary)

**On-chain (Sui Move):**
- `RiskPolicy` object — stores current LTV caps, pause flags, oracle deviation thresholds, owner = multisig `Cap`.
- `RiskOracle` shared object — receives signed score updates from off-chain agent (Ed25519 key registered in policy).
- `OverrideCap` — held by DAO multisig; can call `revert_action(action_id)` within `revert_window_ms`.
- Lender integration = 1 import + 1 assert per sensitive entry function.

**Off-chain:**
- Price ingestion: Pyth pull oracle + Switchboard secondary feed.
- Risk scorer: containerized Python service (FastAPI), rule layer + sklearn logistic model trained on labeled incidents (Stream, Euler, Aave-CAPO).
- Action executor: Node.js + `@mysten/sui` SDK; builds PTBs, signs with RiskGuard hot key (capped scope), submits.
- Frontend: Next.js + dApp-kit, zkLogin for DAO members.
- Storage: Walrus for incident PDFs / replay datasets (optional v1).

**Data flow:**
Pyth → scorer (sub-second) → if threshold crossed → executor builds PTB `[update_score, set_ltv, emit_event]` → on-chain → indexer → dashboard + Telegram → DAO inspects → optional revert.

---

## 10. Business Model

- **Pricing hypothesis** (anchored to Chaos Labs / Hypernative public deals):
  - Starter: $5k/mo, 1 market, basic rules.
  - Growth: $15k/mo, up to 5 markets, custom rules, backtests.
  - Enterprise: $25k+/mo or 0.05% of TVL covered/yr (whichever higher), Seal-encrypted weights, dedicated risk engineer.
- **Secondary revenue:** insurance underwriting feed licensing; LP-facing audit reports as add-on $2k/mo.
- **Unit economics target:** gross margin > 80% (compute is the only material COGS); LTV/CAC > 5 given 18-24mo contracts.

---

## 11. Go-to-Market

- **First 5 customers:** warm intros via Sui Foundation BD; Suilend, Navi, Momentum, Bluefin, Bucket are all the priority list — they collectively are >90% of Sui DeFi TVL.
- **First 100 users** (operators inside protocols + LPs): content marketing tied to **post-mortem replays** — "we replayed Stream on RiskGuard, it would have saved $X". Format borrowed from rekt.news.
- **Distribution channels:** Sui Foundation Demo Day, Sui Builder House sponsorships, Aave/Compound-style governance proposals on each Sui DAO.
- **Trojan horse:** free "Risk Replay" tool that backtests any Sui market against historical de-peg scenarios — captures protocol risk teams' emails.

---

## 12. Hackathon Demo Plan (3 min)

| Time | Action | Sub-track criterion hit |
|---|---|---|
| 0:00-0:20 | Pitch: "Aave loses $230M to static LTV. Sui's $2.6B TVL has zero native risk agent. Watch." | Real-World relevance |
| 0:20-0:50 | Show live Pyth feed in dashboard, risk score = 0.12 (green). | **Live price feed** ✓, **Visible AI risk score** ✓ |
| 0:50-1:30 | Trigger simulated BUCK depeg via dev tool. Score climbs to 0.84. Policy object autonomously executes PTB cutting LTV 85%→50% on devnet Suilend fork. Show transaction in Sui Explorer. | **≥1 autonomous on-chain action** ✓ |
| 1:30-2:00 | DAO multisig (3 signers in browser tabs) clicks "Revert". On-chain `RevertPolicy` event. LTV restored. | **Human override** ✓ |
| 2:00-2:40 | Show audit log: every action, rationale, signer, gas. Open PDF LP report. | Real-World + UX |
| 2:40-3:00 | Close: roadmap → testnet with Suilend, mainnet Q4, $1M ARR target year 1. Why Sui: Move policy object enforcement, not webhooks. | Vision / Sui-specific |

**Scoring math (handbook weights: Real-World 50 / UX 20 / Tech 20 / Vision 10):**
- Real-World 47/50 (clear B2B buyer, named protocols, dollar pain).
- UX 16/20 (clean dashboard, override button is the wow moment).
- Tech 18/20 (Pyth + Move policy + PTB + multisig override, all real).
- Vision 9/10 (path to Seal, cross-protocol contagion).
**Projected 90/100.**

---

## 13. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Crowded sub-track — many teams pick Risk Guardian | High | Differentiate via **Move policy object enforcement** (not alerts) + named design-partner LOI before demo day |
| AI model looks like a "magic box" to judges | High | Ship a deterministic rule layer as the primary scorer; ML is a tiebreaker. Show rule traces on dashboard. |
| No real protocol partner = no credibility | Medium | Cold-email Suilend, Navi, Bucket risk leads in week 1; offer pilot free for 90 days in exchange for logo + LOI |
| Pyth feed downtime during demo | Medium | Pre-record fallback video; also wire Switchboard as backup live |
| Move policy object pattern not yet idiomatic — judges may question safety | Medium | Reference Sui Kiosk's `TransferPolicy` as the established analogue; security review by `sui-security-guard` + `sui-red-team` skills |
| Hypernative announces Sui product before mainnet | Medium | Build moat via: (a) protocol-specific custom rules, (b) DAO-owned policy objects (incumbents can't replicate without permission), (c) Sui Foundation co-marketing |
| Regulatory: "autonomous AI taking risk actions" is a compliance hot potato | Low-Med | DAO override + full audit trail + opt-in per protocol; positioned as decision-support with mandatory revert window |

---

## 14. Open Questions

- Does Hypernative already have a Sui-native product (not just announcement)? gemini didn't surface one but couldn't confirm negative — needs direct check with Sui Foundation BD.
- TAM numbers for "DeFi risk tooling" cited above are aggregated from publicly-accessible MarketsandMarkets, Grand View Research, and MarketIntelo report summaries; primary full reports are paywalled. Treat as order-of-magnitude only — narrowed estimate ($14-21B) is the adjacent-security TAM, not the broader DeFi market.
- Will top Sui lenders (Suilend, Navi) accept a *third-party*-owned policy object in their core lending path, or will they demand RiskGuard ship a library they self-deploy? Affects pricing model.
- Seal integration maturity by hackathon date — is the SDK stable enough to demo encrypted weights, or push to v2?
- Bluefin perp risk needs different signals (funding, OI skew) than lending — does MVP scorer generalize or do we need a per-protocol model?
- Are Sui DAOs structured enough today (multisig participation, voting cadence) to act as a meaningful override layer, or is this just theater? Worth interviewing 2-3 actual Sui DAO ops.
- Pricing anchor of "% of TVL covered" — what % did Chaos Labs actually charge Aave? Public proposals show fixed retainer ($1-2M/yr); the % framing is RiskGuard's hypothesis, not confirmed market price.
