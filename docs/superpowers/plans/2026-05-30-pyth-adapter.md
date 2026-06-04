# pyth_adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Repo note:** This directory is NOT git-initialized. "Commit" steps are logical checkpoints — run `git init` first if you want real commits, otherwise treat each as a "stop, build, verify green" gate. Do not block on git.
>
> **Skill routing (project rule):** Move code → after each module compiles/tests, the final review runs `move-code-quality` → `sui-security-guard` → `sui-red-team`. Do NOT use the generic code-reviewer on `.move` files.

**Goal:** Add `pyth_adapter.move` — the only production path that mints an `oracle::PriceReading`, by decoding a real Pyth `PriceInfoObject` and binding it to the per-market expected feed id.

**Architecture:** New `pyth_adapter` module depends on `oracle` (mint `PriceReading`, read `expected_feed_id` + `max_staleness_ms`) and on Pyth/Wormhole packages. `oracle` gains a per-oracle `expected_feed_id` field (deploy-time config, set at `register_market`). `post_score_and_apply`'s external ABI is unchanged. The adapter splits a thin `PriceInfoObject`-decoding wrapper (`read_price`, integration-tested off-chain) from a pure `compute_reading` (unit-tested with primitives).

**Tech Stack:** Sui Move 2024.beta, Pyth Sui contracts (`get_price_no_older_than`), Wormhole (Pyth dep).

**Design doc:** `docs/superpowers/specs/2026-05-30-pyth-adapter-design.md`

---

## File Structure

- **Modify** `move/riskguard/Move.toml` — add Pyth + Wormhole git deps + addresses.
- **Modify** `move/riskguard/sources/oracle.move` — `expected_feed_id` field; `new_oracle` param+asserts; `expected_feed_id()` getter; production `new_price_reading`; keep `new_oracle_for_testing` signature (inject dummy feed id); `new_price_reading_for_testing` delegates.
- **Modify** `move/riskguard/sources/admin.move` — `register_market<M>` takes `expected_feed_id`, threads into `new_oracle`.
- **Create** `move/riskguard/sources/pyth_adapter.move` — `read_price` (thin) + `compute_reading` (pure) + unit tests.
- **Modify** `move/riskguard/tests/admin_tests.move` — pass `expected_feed_id` to the 5 `register_market` call sites.

---

## Task 1: Move.toml Pyth/Wormhole deps + compile smoke

> Highest-risk task. Pyth/Wormhole pull their own Sui framework rev, which can conflict with the
> CLI-managed implicit framework. If `sui move build` errors on a duplicate/incompatible `Sui`
> dependency, add an explicit pinned `Sui` dep with `override = true` (see Step 3 fallback).

**Files:**
- Modify: `move/riskguard/Move.toml`

- [ ] **Step 1: Add deps to Move.toml**

Replace the `[dependencies]` block (keep `[package]` and `[addresses]` as-is, but add the two pyth/wormhole addresses):

```toml
[dependencies]
# Framework deps (Sui, MoveStdlib) auto-managed by the CLI for Sui 1.45+.
Pyth = { git = "https://github.com/pyth-network/pyth-crosschain.git", subdir = "target_chains/sui/contracts", rev = "sui-contract-testnet" }
Wormhole = { git = "https://github.com/wormhole-foundation/wormhole.git", subdir = "sui/wormhole", rev = "sui/testnet" }

[addresses]
riskguard = "0x0"
```

> Note: `rev` values are branch names (Pyth's own testnet convention) — they track upstream and are
> not commit-pinned. Acceptable for testnet/hackathon; pin a commit hash before mainnet.

- [ ] **Step 2: Build to fetch deps and surface conflicts**

Run: `cd move/riskguard && sui move build`
Expected (success): compiles, downloads Pyth/Wormhole. Existing 5 modules still build.
Expected (possible failure): error mentioning duplicate/conflicting `Sui` framework dependency → go to Step 3.

- [ ] **Step 3 (only if Step 2 failed on framework conflict): pin + override Sui framework**

Add to `[dependencies]`, matching the rev Pyth/Wormhole expect (read it from the error or from the fetched `Wormhole` Move.toml under `~/.move`):

```toml
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "framework/testnet", override = true }
```

Re-run `sui move build`. If a different rev is required, the build error names it — use that rev.

- [ ] **Step 4: Verify existing tests still pass with new deps**

Run: `cd move/riskguard && sui move test`
Expected: the existing 32 tests still pass (deps added, no source change yet).

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/Move.toml move/riskguard/Move.lock
git commit -m "build: add Pyth + Wormhole testnet deps"
```

---

## Task 2: oracle.move — expected_feed_id field + production PriceReading constructor

**Files:**
- Modify: `move/riskguard/sources/oracle.move`

- [ ] **Step 1: Add the field to `RiskOracle`**

In `public struct RiskOracle has key { ... }`, add after `max_staleness_ms: u64,`:

```move
    expected_feed_id: vector<u8>,   // Pyth price identifier (32 bytes), per-market deploy-time config
```

- [ ] **Step 2: Update `new_oracle` signature + asserts + initializer**

Replace the existing `new_oracle`:

```move
public(package) fun new_oracle(
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,
    ctx: &mut TxContext,
): RiskOracle {
    // >= 1000 (not just > 0): pyth_adapter derives Pyth's seconds-granularity max_age as
    // max_staleness_ms / 1000; a sub-second window would floor to 0s and reject every reading.
    assert!(max_staleness_ms >= 1000, EBadConfig);
    assert!(expected_feed_id.length() == 32, EBadConfig);  // Pyth identifiers are 32 bytes
    RiskOracle {
        id: object::new(ctx),
        active: true,
        latest_score_bps: 0,
        latest_score_ts_ms: 0,
        nonce: 0,
        max_staleness_ms,
        expected_feed_id,
    }
}
```

- [ ] **Step 3: Add getter + production `new_price_reading`**

Add `expected_feed_id` getter next to the other read helpers:

```move
public fun expected_feed_id(oracle: &RiskOracle): vector<u8> { oracle.expected_feed_id }
```

Add the production constructor in the construction section (this is the only non-test PriceReading mint path; `public(package)` so only `pyth_adapter` reaches it):

```move
/// Production constructor for `PriceReading` — the ONLY non-test mint path.
/// `public(package)` so only in-package callers (pyth_adapter, fed by a verified Pyth read)
/// can mint one. See PriceReading's TRUST INVARIANT doc.
public(package) fun new_price_reading(conf_bps: u16, publish_ts_ms: u64): PriceReading {
    PriceReading { conf_bps, publish_ts_ms }
}
```

- [ ] **Step 4: Keep `new_oracle_for_testing` signature, inject dummy feed id; delegate the reading minter**

Replace the two test-only helpers so existing oracle tests (which call the 2-arg form) compile unchanged:

```move
#[test_only]
public(package) fun new_oracle_for_testing(max_staleness_ms: u64, ctx: &mut TxContext): RiskOracle {
    // 32-byte dummy feed id — keeps the existing 2-arg test call sites untouched.
    new_oracle(max_staleness_ms, x"00000000000000000000000000000000000000000000000000000000000000aa", ctx)
}

#[test_only]
public(package) fun new_price_reading_for_testing(conf_bps: u16, publish_ts_ms: u64): PriceReading {
    new_price_reading(conf_bps, publish_ts_ms)
}
```

> The existing oracle test at the `new_oracle_for_testing(0, ...)` call site expects `EBadConfig`
> (was `> 0`, now `>= 1000`); 0 still aborts `EBadConfig`, so that test stays green.

- [ ] **Step 5: Build**

Run: `cd move/riskguard && sui move build`
Expected: compiles. (`admin.move` still calls 2-arg `new_oracle` → will error here; that's Task 3. If you want a clean build at this checkpoint, do Task 3 Step 1 now, then build. Otherwise expect the admin.move arity error and proceed to Task 3.)

- [ ] **Step 6: Add a unit test for the 32-byte feed id assert**

In `tests/oracle_tests.move`, add (uses production `new_oracle` directly to exercise the new param):

```move
#[test]
#[expected_failure(abort_code = oracle::EBadConfig)]
fun bad_feed_id_length_aborts() {
    let mut ctx = tx_context::dummy();
    let o = oracle::new_oracle(60_000, x"00aa", &mut ctx);  // 2 bytes, not 32
    oracle::share_oracle(o);
}
```

> If `EBadConfig` is not already `public` in oracle.move, change the const to `public(package)` or
> reference the literal `21` per the existing test convention in this file. Check how other
> `expected_failure` aborts in `oracle_tests.move` reference the code and match that style.

- [ ] **Step 7: Run oracle tests after Task 3 compiles (deferred)**

oracle tests can only run once the package builds, which needs Task 3. Note this and continue.

- [ ] **Step 8: Commit**

```bash
git add move/riskguard/sources/oracle.move move/riskguard/tests/oracle_tests.move
git commit -m "feat(oracle): per-market expected_feed_id + production new_price_reading"
```

---

## Task 3: admin.move — thread expected_feed_id through register_market

**Files:**
- Modify: `move/riskguard/sources/admin.move`
- Modify: `move/riskguard/tests/admin_tests.move`

- [ ] **Step 1: Add param to `register_market<M>` and thread into `new_oracle`**

Add `expected_feed_id: vector<u8>,` to the param list (place it right after `max_staleness_ms: u64,`), and update the `new_oracle` call:

```move
public fun register_market<M>(
    _admin: &AdminCap,
    ltv_default_bps: u16,
    revert_window_ms: u64,
    min_loosen_interval_ms: u64,
    max_conf_bps: u16,
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,
    publisher_recipient: address,
    stop_recipient: address,
    override_recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let oracle = oracle::new_oracle(max_staleness_ms, expected_feed_id, ctx);
    // ... rest unchanged
```

- [ ] **Step 2: Update the 5 `register_market` call sites in admin_tests.move**

At each call site (lines ~54, ~102, ~121, ~138, ~142), insert a 32-byte feed-id argument right after the `max_staleness_ms` argument. Use:

```move
        x"00000000000000000000000000000000000000000000000000000000000000aa",
```

> Read each call site to place the new arg in the correct position (after the `max_staleness_ms`
> value, before `publisher_recipient`). The exact surrounding args differ per test; match position by
> the param order in Step 1.

- [ ] **Step 3: Build**

Run: `cd move/riskguard && sui move build`
Expected: compiles cleanly (oracle.move + admin.move now consistent).

- [ ] **Step 4: Run full existing suite**

Run: `cd move/riskguard && sui move test`
Expected: all previous tests + the new `bad_feed_id_length_aborts` pass (33 total), 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/admin.move move/riskguard/tests/admin_tests.move
git commit -m "feat(admin): register_market binds per-market Pyth feed id"
```

---

## Task 4: pyth_adapter::compute_reading (pure logic) + unit tests

**Files:**
- Create: `move/riskguard/sources/pyth_adapter.move`

- [ ] **Step 1: Write the module skeleton with the pure fn + failing tests**

Create `sources/pyth_adapter.move` with ONLY the pure logic and tests first (no Pyth imports yet, so it compiles standalone and tests can run):

```move
/// Pyth → RiskGuard trust-boundary translator. Decodes a verified Pyth `PriceInfoObject`
/// into an `oracle::PriceReading` (the only production mint path). `read_price` is the thin
/// PriceInfoObject-decoding wrapper (off-chain PTB integration-tested); `compute_reading` is the
/// pure, unit-tested core. See docs/superpowers/specs/2026-05-30-pyth-adapter-design.md.
module riskguard::pyth_adapter;

use riskguard::oracle::{Self, RiskOracle, PriceReading};

const MAX_BPS: u16 = 10_000;

const EWrongFeed: u64    = 30;  // PriceInfoObject feed id != oracle.expected_feed_id
const EInvalidPrice: u64 = 31;  // price <= 0 (BUCK/USD must be positive)

/// Pure core: feed-id bind + price sign/zero check + conf_bps (saturated) + construct.
/// Takes primitives so it is unit-testable without any Pyth type.
/// conf and price share Pyth's `expo`, so it cancels: conf_bps = conf * 10000 / price_mag.
fun compute_reading(
    expected_feed: vector<u8>,
    actual_feed: vector<u8>,
    price_mag: u64,
    price_is_negative: bool,
    conf: u64,
    publish_ts_secs: u64,
): PriceReading {
    assert!(actual_feed == expected_feed, EWrongFeed);
    assert!(!price_is_negative && price_mag > 0, EInvalidPrice);
    let bps_u128 = (conf as u128) * (MAX_BPS as u128) / (price_mag as u128);
    let conf_bps = if (bps_u128 > (MAX_BPS as u128)) MAX_BPS else (bps_u128 as u16);
    oracle::new_price_reading(conf_bps, publish_ts_secs * 1000)
}

#[test_only] use riskguard::oracle::{reading_conf_bps, reading_publish_ts_ms};

#[test]
fun happy_path_conf_bps_and_ts() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    // price = 1_000_000 (BUCK ~1.0 at expo -6), conf = 2_000 → 2000*10000/1000000 = 20 bps
    let r = compute_reading(feed, feed, 1_000_000, false, 2_000, 1_700);
    assert!(reading_conf_bps(&r) == 20, 0);
    assert!(reading_publish_ts_ms(&r) == 1_700_000, 1);
}

#[test]
#[expected_failure(abort_code = EWrongFeed)]
fun wrong_feed_aborts() {
    let exp = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let act = x"00000000000000000000000000000000000000000000000000000000000000bb";
    let _r = compute_reading(exp, act, 1_000_000, false, 2_000, 1_700);
    abort 99
}

#[test]
#[expected_failure(abort_code = EInvalidPrice)]
fun negative_price_aborts() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let _r = compute_reading(feed, feed, 1_000_000, true, 2_000, 1_700);
    abort 99
}

#[test]
#[expected_failure(abort_code = EInvalidPrice)]
fun zero_price_aborts() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let _r = compute_reading(feed, feed, 0, false, 2_000, 1_700);
    abort 99
}

#[test]
fun blown_conf_saturates_to_max_bps() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    // conf huge vs price → ratio >> MAX_BPS → must saturate, not wrap.
    let r = compute_reading(feed, feed, 1, false, 18_446_744_073_709_551_615, 1_700);
    assert!(reading_conf_bps(&r) == MAX_BPS, 0);
}
```

- [ ] **Step 2: Run the adapter unit tests**

Run: `cd move/riskguard && sui move test pyth_adapter`
Expected: 5 tests pass. (`reading_conf_bps` / `reading_publish_ts_ms` already exist as public getters in oracle.move.)

> If `compute_reading` being a private `fun` blocks the tests, they are in the same module so it is
> reachable. If `oracle::new_price_reading` (public(package)) errors, confirm `pyth_adapter` is in
> the same package (it is) — package visibility covers it.

- [ ] **Step 3: Commit**

```bash
git add move/riskguard/sources/pyth_adapter.move
git commit -m "feat(pyth_adapter): pure compute_reading + unit tests"
```

---

## Task 5: pyth_adapter::read_price (Pyth decoding wrapper)

**Files:**
- Modify: `move/riskguard/sources/pyth_adapter.move`

- [ ] **Step 1: Add Pyth imports + the thin wrapper**

Add to the `use` block at the top:

```move
use sui::clock::Clock;
use pyth::pyth;
use pyth::price_info::{Self, PriceInfoObject};
use pyth::price_identifier;
use pyth::price;
use pyth::i64;
```

Add the public entry the PTB calls (after `compute_reading`):

```move
/// Decode a verified Pyth reading into a `PriceReading`. The off-chain executor calls this in the
/// same PTB, AFTER `SuiPythClient.updatePriceFeeds` has refreshed `price_info_object`, and BEFORE
/// `oracle::post_score_and_apply`. Uses Pyth's canonical `get_price_no_older_than` (never
/// `get_price_unsafe`) with the per-oracle staleness window; the feed-id bind reads directly from
/// `oracle` so the checked feed and the written oracle are the same object (no caller discretion).
public fun read_price<M>(
    oracle: &RiskOracle,
    price_info_object: &PriceInfoObject,
    clock: &Clock,
): PriceReading {
    // Staleness: seconds granularity from the single config. new_oracle asserts >= 1000ms,
    // so this is always >= 1. Aborts inside Pyth if stale.
    let max_age_secs = oracle::max_staleness_ms(oracle) / 1000;
    let p = pyth::get_price_no_older_than(price_info_object, clock, max_age_secs);

    let info = price_info::get_price_info_from_price_info_object(price_info_object);
    let id = price_info::get_price_identifier(&info);
    let actual_feed = price_identifier::get_bytes(&id);

    let price_i64 = price::get_price(&p);
    let price_is_negative = i64::get_is_negative(&price_i64);
    // get_magnitude_if_positive aborts if negative; guard so compute_reading owns the EInvalidPrice
    // semantics uniformly. When negative we pass mag=0 → compute_reading aborts EInvalidPrice.
    let price_mag = if (price_is_negative) 0 else i64::get_magnitude_if_positive(&price_i64);

    compute_reading(
        oracle::expected_feed_id(oracle),
        actual_feed,
        price_mag,
        price_is_negative,
        price::get_conf(&p),
        price::get_timestamp(&p),   // u64 seconds
    )
}
```

- [ ] **Step 2: Build**

Run: `cd move/riskguard && sui move build`
Expected: compiles with Pyth deps resolved. If `i64`/`price` module paths differ from the error message, adjust the `use` paths to match the fetched Pyth package (verified API: `pyth::price`, `pyth::i64`, `pyth::price_info`, `pyth::price_identifier`, `pyth::pyth`).

- [ ] **Step 3: Run full suite (read_price has no on-chain unit test — see note)**

Run: `cd move/riskguard && sui move test`
Expected: all tests pass (33 + 5 adapter = 38), 0 warnings.

> `read_price`'s PriceInfoObject decoding is NOT unit-tested on-chain (Pyth exports no public
> test constructor for `PriceInfoObject`). It is covered by off-chain PTB integration tests using
> `SuiPythClient.updatePriceFeeds` (separate TS task, not in this Move plan). This gap is
> intentional and must be stated in move-notes — do not claim full coverage (Rule 12).

- [ ] **Step 4: Commit**

```bash
git add move/riskguard/sources/pyth_adapter.move
git commit -m "feat(pyth_adapter): read_price PriceInfoObject decoding wrapper"
```

---

## Task 6: Reviews + move-notes

**Files:**
- Modify: `move/riskguard/../move-notes.md` (project root `move-notes.md`)

- [ ] **Step 1: Monkey tests (per .claude/rules/test.md)**

Add to `pyth_adapter.move` tests — extreme inputs:

```move
#[test]
fun monkey_conf_equals_price_is_max_bps() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let r = compute_reading(feed, feed, 1_000_000, false, 1_000_000, 1); // conf==price → 10000 bps
    assert!(reading_conf_bps(&r) == MAX_BPS, 0);
}

#[test]
fun monkey_conf_one_over_max_price_is_zero_bps() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let r = compute_reading(feed, feed, 18_446_744_073_709_551_615, false, 1, 1); // tiny ratio → 0
    assert!(reading_conf_bps(&r) == 0, 0);
}
```

Run: `cd move/riskguard && sui move test pyth_adapter`
Expected: all adapter tests pass.

- [ ] **Step 2: move-code-quality review**

Invoke the `sui-dev-agents:move-code-quality` skill on `sources/pyth_adapter.move` and the oracle/admin diffs. Fix any Move Book violations (param order objects-first, naming, error const style). Re-run `sui move test`.

- [ ] **Step 3: sui-security-guard scan**

Invoke `sui-dev-agents:sui-security-guard`. Expected: 0 secret hits (deps add no secrets). Confirm `.gitignore` still covers build artifacts.

- [ ] **Step 4: sui-red-team (new trust-boundary code)**

Invoke `sui-dev-agents:sui-red-team` on the adapter. Enumerate ≤5 vectors and confirm defenses:
1. Substitute a different (easier-to-manipulate) feed's PriceInfoObject → `EWrongFeed` (feed-id bind).
2. Feed a stale price → Pyth `get_price_no_older_than` aborts.
3. Blow out confidence to wrap conf_bps small → u128 + saturation prevents wrap.
4. Negative/zero price → `EInvalidPrice`.
5. Call `read_price` without the publisher cap to forge a reading → reading alone is inert; `post_score_and_apply` still requires the cap. (Confirm `PriceReading` has no `store` so it can't be parked.)

Expected: 0 EXPLOITED.

- [ ] **Step 5: Final full suite**

Run: `cd move/riskguard && sui move test`
Expected: all tests pass, 0 warnings. Record the exact total.

- [ ] **Step 6: Update move-notes.md**

Append a section: modules touched (oracle/admin/pyth_adapter + Move.toml), the Option 2→1 upgrade, the Rule 7 conflict resolution (NOT pure append — struct field added; only the external `post_score_and_apply` ABI is unchanged), the upgrade-compatibility constraint (no fields added to `RiskOracle` post-mainnet), the intentional `read_price` coverage gap (off-chain PTB integration), test total, and the branch-not-commit `rev` pinning caveat.

- [ ] **Step 7: Commit**

```bash
git add move/riskguard/sources/pyth_adapter.move move-notes.md
git commit -m "test(pyth_adapter): monkey tests + reviews + move-notes"
```

---

## Self-Review (author checklist — completed)

- **Spec coverage:** §3 DAG → Task 4/5 imports; §4 read_price → Task 5; §4 compute_reading → Task 4; §5 oracle changes → Task 2; §5 upgrade constraint → Task 6 Step 6; §6 admin → Task 3; §7 deps → Task 1; §8 testing split + monkey + reviews → Task 4/5/6. All covered.
- **Placeholder scan:** every code step has concrete code; the only deferred items (exact Sui framework `rev` for the override fallback; exact Pyth `use` paths) are surfaced as build-error-driven adjustments with the verified module names, not blind TODOs.
- **Type consistency:** `expected_feed_id: vector<u8>` (32 bytes) used in oracle field, `new_oracle`, getter, `register_market`, `compute_reading` arg. `new_price_reading(conf_bps: u16, publish_ts_ms: u64)` consistent between oracle def and both adapter + test callers. `compute_reading` arg order identical in Task 4 def and Task 5 call. Error codes `EWrongFeed=30`/`EInvalidPrice=31` consistent.
