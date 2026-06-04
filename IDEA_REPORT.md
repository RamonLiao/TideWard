# RiskGuard

**One-line pitch:** Autonomous AI risk guardian SaaS for Sui lending/perp protocols — live oracle ingest, on-chain parameter adjustment via Move policy object, DAO override.

**Problem it solves:** DeFi protocols rely on static risk params (LTV, IR). De-peg / flash-crash makes them obsolete in seconds; institutional LPs distrust manual ops.

**Core mechanism:** Pyth/Switchboard feed → AI risk score → Move policy object autonomously bumps LTV / pauses market via PTB → every action logged on-chain → DAO can revert.

**Why this track:** Directly hits Sub-track 1 Autonomous Risk Guardian must-haves (live feed, visible score, ≥1 autonomous on-chain action, human override). Move policy object as the *enforcement* primitive — answers "why Sui specifically."

**Win probability:** 82
- Sub-track must-haves are explicit and demoable. B2B SaaS story strong on Real-World (50%). Risk: many teams will pick this same sub-track.

**Key risks:** Crowded sub-track; AI model quality hard to validate in demo; needs a real partner protocol for credibility.

**Required Sui primitives:** Move policy objects, PTBs, Pyth oracle, optional Seal for confidential risk params.

**MVP scope:** Devnet lending fork + Pyth feed + simple risk scorer (rule-based + small ML) + dashboard + DAO override button + one autonomous LTV adjustment demo.
