# TideWard — Demo Script

> Sui Overflow 2026 · Track 0 Agentic Web · Sub-track 1 Autonomous Risk Guardian
> Network: testnet · pkg `0x696e0999…6997fc8`

## What this is / when it's used (the 30s framing)

A **circuit-breaker + DAO brake** for Sui lending/perp protocols, sitting between a
risk feed and the protocol's params. Lending protocols use **static LTV** and
**human governance** (days to react). On a de-peg / oracle blowout, money is gone in
seconds. TideWard makes risk an **on-chain primitive**:

| Layer | Action | Primitive | Where in app |
|---|---|---|---|
| Off-chain AI agent | reads Pyth → score crosses threshold → auto-tighten LTV / pause | `oracle::post_score_and_apply<M>` | Markets card SCORE / LTV (`pnpm apply`) |
| Protocol contract | one assert before borrow | `policy::assert_borrow_allowed` | integrator one-liner |
| DAO (human brake) | REVERT within window / instant PAUSE / force-tighten | `OverrideCap` / `EmergencyStopCap` / `AdminCap` | Emergency / Override tab + drawer |

Pitch: integrate one assert line → autonomous tightening (sub-second, no governance
vote) + DAO time-boxed revert, scoped **per market** via Sui's object model
(`Policy<SUI>` ≠ `Policy<USDC>`) — that's the "why Sui".

## Honest scope (say this, don't get caught)
- ✅ Built + live on testnet: full Move contracts + DAO console (5 tabs, cap-gated); reads are live.
- ✅ Autonomous on-chain action is real via `pnpm apply` (live Pyth update → tighten).
- ⚠️ Off-chain Python scorer / Node executor service: NOT built. The score is pushed by the `apply` script standing in for the agent.

## Pre-flight checklist
1. **Connected browser wallet MUST own the caps** (AdminCap / EmergencyStopCap / OverrideCap),
   all held by the deploy/operator addr `0xbdecf8a2…3ee01f`. Import that key into the
   demo wallet, else every button is disabled (read-only).
2. `app/.env.local` → testnet (done). `cd app && pnpm dev`.
3. `cd ts` — `pnpm apply` works (verified: digest `BLmcgXoG…`).
4. **Stage a high baseline LTV** so the crisis drop is dramatic. Current on-chain LTV is
   already crunched (~3000). To reset high, loosen first (subject to throttle):
   `pnpm apply 1000 5000 0` then wait `minLoosenIntervalMs` (5s) before the live crisis run.
5. **Revert window is 60s** (`REGISTER.revertWindowMs`). After `apply`, you have 60s to
   demo the DAO REVERT before the window closes. Pending list caps at 8 (auto-prunes).

## Script (~4 min, maps to the 4 sub-track must-haves)

**[0:00] Open (spoken)** — static risk params + human governance = too slow on de-peg.
TideWard makes risk an on-chain primitive: auto-tighten, DAO time-boxed revert, per-market blast radius.

**[0:30] ① Live feed + visible score** (must-have 1+2) → **Markets** tab
- Point at SUI/USD card: `LTV bps` / `SCORE` / `STALE Ns` (live testnet) / `PENDING` / `● ACTIVE` / flags.
- Open drawer: score, nonce, max_staleness, revert window.

**[1:15] ② Autonomous intervention** (must-have 3) → terminal
- `cd ts && pnpm apply` → live Pyth update, score 8500, LTV auto-drops, new PENDING #N, event on ticker.
- "No human clicked anything — the agent tightened on score, sub-second, zero governance latency."

**[2:30] ③ DAO human brake** (must-have 4) → drawer / **Override** tab
- "False alarm" → PENDING has a live **revert-window countdown** → click **REVERT** → LTV restores,
  `ActionReverted` on Override tab.
- Bonus → **Emergency**: `⏸ PAUSE ORACLE` (EmergencyStopCap, single-sig, instant) = one-click kill the market.

**[3:15] ④ Anti-rug governance: timelock** → **Upgrades** tab
- Point at `cap version / 72h timelock`. "Agent can move params but CANNOT change policy logic —
  upgrades need 72h timelock + AdminCap, DAO can CANCEL anytime." (trust boundary = judge points)

**[3:45] Close** — one assert line = auto-tighten + DAO time-boxed revert + per-market isolation, native to Sui.

## Fallback if `apply` fails live (Hermes/Pyth flaky)
Use the drawer's **force_protect** to lower LTV as the "tighten" — but say it's the manual DAO
path, which weakens the autonomous claim. Keep `apply` as primary.
