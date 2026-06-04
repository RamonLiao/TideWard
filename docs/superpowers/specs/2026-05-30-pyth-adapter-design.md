# pyth_adapter — Design

> Date: 2026-05-30
> Status: Approved (brainstorming)
> Depends on: `oracle.move`, `policy.move`, `caps.move`, `admin.move` (all implemented, 32 tests green)
> Upgrades the Pyth seam from **Option 2 (stub `PriceReading`)** to **Option 1 (real Pyth read)**.

## 1. Goal

Provide the **only production path** that mints an `oracle::PriceReading`, by decoding a real
Pyth `PriceInfoObject` on-chain. This closes threat #4 (forged freshness datum): holding a
production `PriceReading` becomes proof it came from a verified Pyth read of the *bound* feed.

`oracle::post_score_and_apply<M>`'s ABI is **unchanged** — the off-chain executor's existing
3-step PTB still works; step ② just swaps the test minter for `pyth_adapter::read_price`.

## 2. Scope & non-goals

In scope:
- New module `sources/pyth_adapter.move`.
- `oracle.move`: add `expected_feed_id` field to `RiskOracle`; add production `public(package) new_price_reading`; add getter; tighten staleness assert.
- `admin.move`: `register_market<M>` takes `expected_feed_id`, threads it into `new_oracle`.
- `Move.toml`: add Pyth + Wormhole deps (testnet).
- Tests for the adapter + updated oracle/admin tests for the new param.

Non-goals (explicitly deferred):
- Cetus TWAP secondary source (spec §9.5 v1, mainnet-only).
- Switchboard second source (P1 backlog).
- Changing `post_score_and_apply` validation logic — it stays the single freshness/conf/replay authority.

## 3. Architecture

### 3.1 Module DAG (Rule 8 — no cycles)

```
pyth_adapter ──► oracle ──► policy
     │              ▲
     └──► pyth      │ (post_score_and_apply takes PriceReading; oracle never imports adapter)
          (wormhole)
```

`pyth_adapter` depends on `oracle` (to mint `PriceReading` and read `expected_feed_id`) and on the
Pyth/Wormhole packages. `oracle` does **not** depend on `pyth_adapter` — that is what keeps
`post_score_and_apply`'s ABI stable across the seam upgrade.

### 3.2 On-chain PTB flow (off-chain executor, single transaction)

```
① TS SuiPythClient.updatePriceFeeds(tx, vaas)   → refreshes the shared PriceInfoObject
② pyth_adapter::read_price<M>(oracle, price_info_object, clock) → PriceReading   (copy, drop)
③ oracle::post_score_and_apply<M>(oracle, policy, cap, score_bps, decision, reading, nonce, clock)
```

`PriceReading` has `copy, drop` but **no `store`** — it can only live inside the PTB between calls,
never be parked in an object. That is the seam: the only way to obtain one in a non-test build is
to call `read_price` in the same transaction.

## 4. `pyth_adapter::read_price`

```move
public fun read_price<M>(
    oracle: &RiskOracle,                  // source of truth: expected_feed_id + max_staleness_ms
    price_info_object: &PriceInfoObject,  // refreshed upstream by SuiPythClient.updatePriceFeeds
    clock: &Clock,
): PriceReading
```

Validation order (fail before constructing anything):

1. **Staleness (Pyth canonical):** `price = pyth::get_price_no_older_than(price_info_object, clock, oracle.max_staleness_ms / 1000)`.
   Uses Pyth's recommended safety API (never `get_price_unsafe`); aborts inside Pyth if stale.
   Seconds = `max_staleness_ms / 1000`, derived from the single config (no hardcoded 60).
2. **Feed-ID bind (anti-substitution):** read the `PriceIdentifier` bytes from `price_info_object`
   and assert they equal `oracle.expected_feed_id`. Atomic: the feed checked and the oracle written
   in step ③ are the same object — no caller discretion. Abort `EWrongFeed` on mismatch.
3. **conf_bps:** `Price` carries `price: I64`, `conf: u64`, `expo: I64`; `conf` and `price` share
   `expo`, so it cancels: `conf_bps = conf * 10000 / abs(price)`.
   - `price <= 0` → abort `EInvalidPrice` (BUCK/USD must be positive).
   - compute in u128 to avoid intermediate overflow, then **saturate to `MAX_BPS`** before the u16
     cast so a blown-out confidence can't wrap to a small number and slip past oracle's conf gate.
4. **Construct:** `oracle::new_price_reading(conf_bps, publish_ts_ms)` where `publish_ts_ms` =
   Pyth publish timestamp (seconds) × 1000.

### Errors (module-local plain u64, consistent with oracle.move §2.6 convention)
- `EWrongFeed` — PriceInfoObject feed id ≠ oracle.expected_feed_id
- `EInvalidPrice` — price ≤ 0

(staleness aborts originate inside Pyth's `get_price_no_older_than`.)

### Testability split (research finding 2026-05-30)

Pyth does **not** export a public test-only `PriceInfoObject` constructor (`new_price_info_object`
is `public(friend)`), and the `extend module` workaround is edition/toolchain-fragile. So `read_price`
is split:

- **`read_price` (thin wrapper):** the ~5 lines that call `get_price_no_older_than` and extract
  feed-id / price / conf / timestamp from the `PriceInfoObject`. NOT unit-testable on-chain →
  covered by off-chain PTB integration tests using `SuiPythClient.updatePriceFeeds`.
- **`compute_reading` (pure, private):** takes raw primitives — `expected_feed`, `actual_feed`,
  `price_mag: u64`, `price_is_negative: bool`, `conf: u64`, `publish_ts_secs: u64` — does the
  feed-id compare, price-sign/zero check, conf_bps math + saturation, and constructs the
  `PriceReading`. Fully unit-testable with no Pyth types.

## 5. `oracle.move` changes

```move
public struct RiskOracle has key {
    id: UID,
    active: bool,
    latest_score_bps: u16,
    latest_score_ts_ms: u64,
    nonce: u64,
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,   // NEW — Pyth price identifier (32 bytes), per-market
}

public(package) fun new_oracle(
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,   // NEW
    ctx: &mut TxContext,
): RiskOracle {
    assert!(max_staleness_ms >= 1000, EBadConfig);   // tightened from > 0: sub-second window
                                                     // would floor max_staleness_ms/1000 to 0s
    assert!(expected_feed_id.length() == 32, EBadConfig);  // Pyth identifiers are 32 bytes
    ...
}

public fun expected_feed_id(oracle: &RiskOracle): vector<u8> { oracle.expected_feed_id }

/// Production constructor — the ONLY non-test path that mints a PriceReading.
/// public(package) so only in-package callers (pyth_adapter) can reach it.
public(package) fun new_price_reading(conf_bps: u16, publish_ts_ms: u64): PriceReading {
    PriceReading { conf_bps, publish_ts_ms }
}
```

### Upgrade-compatibility constraint (sui-architect C1 — CRITICAL)

Adding `expected_feed_id` to `RiskOracle` changes the struct layout. SUI Move's upgrade
compatibility check **forbids adding fields to an existing struct in a package upgrade**. This is
only free because the package is **not yet published** (`Move.toml` = `0x0`, deploy still TODO).

Iron rule for production: **once mainnet-live, no further fields may be added to `RiskOracle`.**
Any later per-oracle config must use a dynamic field or a new companion object. `expected_feed_id`
is safe as a direct field because it is written once at `register_market` and never schema-migrated.

Test minter stays but delegates: `new_price_reading_for_testing` → `new_price_reading`.
Trust invariant (codex F3) holds — `#[test_only]` is excluded from production builds; the only
*production* mint path is `new_price_reading`, reachable only from `pyth_adapter`.

## 6. `admin.move` changes

`register_market<M>` gains an `expected_feed_id: vector<u8>` param, threaded into `new_oracle`.
AdminCap-gated, so the feed binding is a governance-controlled, deploy-time config — testnet and
mainnet deploy the same bytecode and differ only in the `expected_feed_id` passed at registration
(testnet BUCK/USD `0xed08…aabf`, mainnet `0xfdf2…7382`; spec §9.5).

## 7. Move.toml deps (resolved during writing-plans)

Add Pyth + Wormhole testnet deps. **Exact git rev + package addresses are version-sensitive and
MUST be verified against current Pyth Sui docs before pinning** (research step in the plan, via the
project's gemini→codex web-search flow — do not pin a possibly-stale rev here). Framework deps stay
CLI-managed.

## 8. Testing

- `pyth_adapter` unit tests need a Pyth `PriceInfoObject`. Pyth exposes test helpers
  (`pyth::price_info::new_price_info_object_for_testing` or equivalent) — **confirm exact API in the
  research step**. Cover:
  - happy path → correct conf_bps + publish_ts_ms
  - wrong feed id → `EWrongFeed`
  - price ≤ 0 → `EInvalidPrice`
  - blown-out conf (conf ≫ price) → conf_bps saturates to `MAX_BPS`, not a wrapped small value
  - stale price → Pyth-internal abort
- Update existing oracle/admin tests for the new `expected_feed_id` param.
- Monkey test (per `.claude/rules/test.md`): conf at u64::MAX, price=1, max_staleness_ms=1000/999, feed id length ≠ 32.
- Then `move-code-quality` → `sui-security-guard` → `sui-red-team` (new trust-boundary code → red-team applies).

## 9. Surfaced conflict (Rule 7)

move-notes claims "Option 2→1 純 append". Only half-true: `post_score_and_apply`'s **external ABI is
unchanged**, but this design adds a field to `RiskOracle` (storage change) and a param to
`new_oracle`/`register_market`. Accepted deliberately — per-oracle feed config is required for
secure multi-market production (a hardcoded const can't onboard a new feed without recompiling, and
caller-passed feed id decouples the check from the written oracle). move-notes to be corrected after
implementation.
```
