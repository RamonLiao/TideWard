# Pyth PTB Integration Test — Design

> Date: 2026-05-31
> Status: Approved (brainstorming) — ready for writing-plans
> Goal: close the deliberate coverage gap in `pyth_adapter::read_price` — its decode of a **real** Pyth `PriceInfoObject` cannot be unit-tested on-chain (Pyth exposes no public test constructor), so it must be exercised off-chain against live Pyth on Sui testnet.

## 1. Why this exists (the gap)

`pyth_adapter.move` is split deliberately:

- `compute_reading(...)` — pure primitive core, fully unit-tested on-chain (feed-id bind, price sign/zero, conf_bps saturation).
- `read_price(oracle, price_info_object, clock)` — thin wrapper that decodes a `pyth::price_info::PriceInfoObject` via `pyth::get_price_no_older_than` + `price`/`i64`/`price_identifier` accessors, then calls `compute_reading`.

The wrapper has **zero on-chain tests** because a real `PriceInfoObject` is unconstructable in a Move test build (`new_price_info_object` is `public(friend)`). This spec covers that wrapper end-to-end with a live testnet PTB.

**Success criterion:** a passing e2e test proving a real Hermes-sourced `PriceInfoObject` decodes into a `PriceReading` that survives `oracle::post_score_and_apply`'s freshness/confidence gates and mutates on-chain state — asserted on decoded values reaching chain state/events, not merely "tx didn't abort". Plus one negative test proving the staleness gate has teeth.

## 2. Scope

- **In:** TS subproject under `ts/`: testnet deploy script, `register_market` script, and a vitest e2e test that runs the full `updatePriceFeeds → read_price → new_decision → post_score_and_apply` PTB against live Pyth on Sui testnet.
- **Out:** Move changes (none needed — see §4), mainnet, BUCK/USD (no confirmed testnet beta feed id), Cetus/Switchboard, Seal.

## 3. Verified facts (gemini → codex, 2026-05-31)

| Item | Value | Status |
|---|---|---|
| npm pkg | `@pythnetwork/pyth-sui-js` | confirmed |
| Hermes fetch | `new SuiPriceServiceConnection(hermes).getPriceFeedsUpdateData([feedId])` → `Buffer[]` | confirmed (returns `Buffer[]`, not `string[]`) |
| PTB update | `new SuiPythClient(suiClient, pythStateId, wormholeStateId).updatePriceFeeds(tx, updates, [feedId])` → `string[]` of PriceInfoObject ids; auto-adds update moveCall + fee | confirmed |
| Pyth State (testnet) | `0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c` | confirmed |
| Wormhole State (testnet) | `0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790` | confirmed |
| Hermes beta endpoint | `https://hermes-beta.pyth.network` | confirmed |
| SUI/USD feed (testnet beta) | `0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266` | confirmed (mainnet SUI/USD `0x23d7…5744` is different — do NOT use on testnet) |
| BTC/USD feed (testnet beta) | `0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b` | confirmed (alternate, unused) |
| BUCK/USD testnet beta id | unknown | not confirmed → excluded |

### Hermes trust positioning (context)
Hermes is Pyth's own price-relay service (open source, `pyth-network/pyth-crosschain` `apps/hermes`). It relays aggregated prices from Pythnet as Wormhole-signed VAAs. **It is a transport layer, not a trust root**: data authenticity is enforced by Wormhole guardian signatures verified by the on-chain Pyth contract during `updatePriceFeeds`. A misbehaving Hermes is an *availability* problem (can't fetch update data), not a *correctness* one. `hermes-beta.pyth.network` is the official testnet/beta instance; mainnet is `hermes.pyth.network`. Public Hermes will require an API key after 2026-07-31 (free as of 2026-05).

## 4. Why no Move changes

`register_market<M>` and `post_score_and_apply<M>` take `M` as a **phantom** market marker (only recorded via `type_name::with_defining_ids<M>()`; `RiskPolicy<M>` carries it phantom). Any published type satisfies the type argument. The test uses `0x2::sui::SUI` as the marker — no new Move marker module, keeping this work purely additive TS.

## 5. Architecture

```
ts/
  package.json          # deps: @mysten/sui, @pythnetwork/pyth-sui-js; dev: tsx, vitest, typescript
  tsconfig.json
  .env.example          # SUI_TESTNET_KEY, (optional) RISKGUARD_PACKAGE_ID, ORACLE_ID, POLICY_ID, PUBLISHER_CAP_ID
  src/
    config.ts           # all verified testnet constants (§3) + feed id + module/function names
    sui.ts              # SuiClient(testnet) + keypair-from-env helpers, object-change extractors
    deploy.ts           # `sui move build` + publish riskguard; print packageId + AdminCap id
    register.ts         # PTB: register_market<0x2::sui::SUI>; extract oracle/policy/caps ids from objectChanges+events
  test/
    e2e.test.ts         # the gap-closing e2e + negative staleness test
```

Each unit has one purpose: `config` = facts, `sui` = client/keypair/extraction plumbing, `deploy`/`register` = one-shot setup scripts, `e2e.test` = the actual verification. `deploy` and `register` are idempotent-ish scripts that print ids to paste into `.env` (or write a `ts/.deployed.json`) so the e2e test reads a fixed deployment rather than redeploying each run.

## 6. Setup flow (one-time, manual)

1. Fund a testnet keypair (faucet). Export `SUI_TESTNET_KEY`.
2. `pnpm deploy` → publishes riskguard, prints `RISKGUARD_PACKAGE_ID` + AdminCap id → write to `ts/.deployed.json`.
3. `pnpm register` → calls `register_market<0x2::sui::SUI>` with:
   - `ltv_default_bps` = e.g. 5000, `revert_window_ms` = e.g. 86_400_000, `min_loosen_interval_ms` = e.g. 3_600_000 (< revert_window, per policy invariant)
   - `max_conf_bps` = `10_000` (MAX — do not reject on confidence; this test targets decode, not the conf gate)
   - `max_staleness_ms` = `60_000` (Hermes publishes ~seconds; `/1000 = 60s` for `get_price_no_older_than`)
   - `expected_feed_id` = `0x50c6…a266` bytes (SUI/USD)
   - the three cap recipients = deployer address
   - extracts `oracle_id`, `policy_id`, `publisher_cap_id` → `ts/.deployed.json`.

## 7. The e2e PTB (gap-closing test)

```
updates = await conn.getPriceFeedsUpdateData([SUI_USD])        // Hermes VAA, Buffer[]
tx = new Transaction()
const [pioId] = await pythClient.updatePriceFeeds(tx, updates, [SUI_USD])  // auto moveCall+fee
const reading  = tx.moveCall(pyth_adapter::read_price,  [oracle, object(pioId), clock])
const decision = tx.moveCall(policy::new_decision,      [new_ltv, flags, reason])
tx.moveCall(oracle::post_score_and_apply<0x2::sui::SUI>,
            [oracle, policy, publisherCap, score_bps, decision, reading, nonce, clock])
execute(tx, {showEvents, showObjectChanges, showEffects})
```

**Assertions (Rule 9 — intent, not just behavior):**
- tx `status == success`.
- `ScorePosted` event emitted with the `score_bps` and `nonce` we passed.
- `ActionExecuted` event emitted (Decision applied → proves `reading` passed all gates and `apply_decision` ran).
- post-exec `oracle.latest_score_bps == score_bps` (decoded reading reached durable state).
- `nonce` is strictly increasing per run (read `current_nonce` first, pass `+1`).

`new_decision` should set a `new_ltv_bps` that differs from current so `apply_decision` records an action (real `ActionExecuted`), and use only known flag bits.

## 8. Negative test (gate teeth)

A green e2e must not be a false positive from a permissive gate. Two complementary negatives:

**Primary — `EReplay` (code 7), deterministic.** Reuse the same fresh `reading` from the positive e2e (or one fresh Hermes update), and call `post_score_and_apply` with a `nonce` **≤ the current oracle nonce**. Assert the tx aborts with `EReplay` (7). This proves `post_score_and_apply`'s replay gate has teeth with zero timing dependence (no Hermes/clock flakiness — §9), and it is the gate this test can actually exercise end-to-end.

**Why not assert `EStaleOracle` (6) here — infeasibility note.** `read_price` derives Pyth's max-age as `max_staleness_ms / 1000` (seconds, floor) while `post_score_and_apply` re-checks at exact-ms granularity against the *same* `oracle.max_staleness_ms`. Floor-to-seconds is therefore always **stricter-or-equal** than the ms check. Because the PTB feeds `read_price`'s output into `post_score_and_apply` within one tx (one `Clock` timestamp), there is **no config** where `read_price` passes but `post_score`'s `EStaleOracle` fires — `read_price` aborts first. So the staleness gate of `post_score` cannot be isolated this way; do not pretend it triggers code 6.

**Secondary — staleness path coverage (generic abort).** Still exercise the staleness branch: register a market with `max_staleness_ms = 1000`, fetch+update a PriceInfoObject, delay past ~1s, then run `read_price` in a separate tx. Assert the tx **fails** (generic) — this abort originates inside Pyth's `get_price_no_older_than`, NOT our `EStaleOracle=6`, so assert on failure, not on our code. Mark this test `skipIf` flaky-timing if it proves unstable; the primary `EReplay` test is the load-bearing negative.

## 9. Risks / preconditions

- **Funded testnet keypair** required (`SUI_TESTNET_KEY`); deploy + register + each e2e run cost gas + Pyth update fee.
- **CLI/protocol alignment:** local `sui` is 1.71.0; Move.toml notes Protocol 124 framework alignment. Before publishing, confirm `sui client active-env` is testnet and `sui move build` passes; if publish reports a framework-version mismatch, switch to a testnet-matching CLI. This is a setup blocker to surface loudly, not silently work around.
- **Hermes beta availability / rate limits:** free as of 2026-05; API key required after 2026-07-31.
- **Test timeouts:** vitest e2e needs long timeouts (~30–60s) for Hermes round-trip + on-chain confirmation.
- **Nonce monotonicity:** the e2e must read `current_nonce` and pass `+1` so repeated runs don't `EReplay`.

## 10. Out of plan (future)
- mainnet config (pin Pyth/Wormhole `rev` to commit hash; real BUCK/USD mainnet feed `0xfdf2…7382`).
- BUCK/USD testnet harness once a confirmed beta feed id is available.
