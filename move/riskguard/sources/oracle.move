/// RiskGuard oracle — the authenticated, freshness-checked entry into the gate.
///
/// `RiskOracle` is a type-erased shared object (spec §2.3: no `phantom M`) holding
/// the latest posted score, replay nonce, and the `active` kill-switch flag.
/// `post_score_and_apply<M>` is the off-chain executor's only write path: it
/// authenticates the publisher cap, enforces price freshness/confidence and
/// replay protection, then delegates the *policy* mutation to
/// `policy::apply_decision` (which owns snapshot + B3 rate-limit + MAX_PENDING).
///
/// DAG note (Rule 8): `oracle → policy`, never the reverse. `policy.move` exposes
/// `public(package) apply_decision`; this module is the only caller.
///
/// Pyth seam (confirmed 2026-05-30): this module takes a `PriceReading` —
/// RiskGuard's own unforgeable freshness datum — NOT a `pyth::PriceInfoObject`.
/// The real decode (`pyth::get_price_no_older_than` + confidence math) lives in a
/// future `pyth_adapter` module behind a separate upstream PTB step, matching the
/// spec §10(6) directive (Pyth update happens upstream, not inside this call).
/// `PriceReading`'s constructor is `public(package)`, so the *only* thing that can
/// mint a production reading is that in-package adapter reading a real Pyth object.
/// Swapping the stub for the real adapter does NOT change this module's ABI.
module riskguard::oracle;

use sui::clock::Clock;
use std::type_name;
use riskguard::caps::{Self, RiskOraclePublisherCap, EmergencyStopCap, AdminCap};
use riskguard::policy::{Self, RiskPolicy, Decision};
use riskguard::events;

// === Errors (spec §2.6 — module-local plain u64, off-chain treats as contract) ===
const EStaleOracle: u64    = 6;   // price older than max_staleness_ms (or future-dated)
const EReplay: u64         = 7;   // nonce not strictly increasing
const EConfTooWide: u64    = 10;  // Pyth confidence exceeds policy.max_conf_bps
const EWrongOracle: u64    = 12;  // cap / policy not bound to this oracle
const EOraclePaused: u64   = 14;  // kill switch engaged
const EBadConfig: u64      = 21;  // constructor: staleness < 1000ms or feed id not 32 bytes

// === Core object ===

public struct RiskOracle has key {
    id: UID,
    active: bool,             // false = every post_score_and_apply aborts (kill switch)
    latest_score_bps: u16,
    latest_score_ts_ms: u64,
    nonce: u64,              // monotonic replay guard (last accepted nonce)
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,   // Pyth price identifier (32 bytes), per-market deploy-time config
}

/// RiskGuard's own freshness datum — the seam that keeps the Pyth dependency out
/// of this module's ABI. Carries only what the on-chain freshness/confidence gate
/// needs. In production it is minted exclusively by `pyth_adapter` (TODO) from a
/// real `PriceInfoObject`, so holding one is proof it came from a real Pyth read
/// (threat #4 teeth).
///
/// TRUST INVARIANT (codex review F3, 2026-05-30): there is deliberately NO
/// production constructor in this chat — only the `#[test_only]` minter below.
/// A real `PriceReading` is therefore unconstructable in a non-test build until
/// `pyth_adapter` adds the verifying constructor. When it does, that constructor
/// MUST be the only `public(package)` path that mints a reading, and it MUST be
/// fed by a decoded `PriceInfoObject` — never by caller-supplied raw numbers.
/// `public(package)` is package-wide reachable, so any new in-package minting
/// path is a trust-boundary change that needs the same scrutiny as the adapter.
public struct PriceReading has copy, drop {
    conf_bps: u16,        // confidence interval as bps of price (conf/price * 10000)
    publish_ts_ms: u64,   // Pyth publish time, normalized to ms
}

// === Construction (package-internal; admin.move wraps + shares, AdminCap-gated) ===

/// Create an oracle, active by default. `max_staleness_ms` must be >= 1000:
/// `pyth_adapter` derives Pyth's seconds-granularity max_age as `max_staleness_ms
/// / 1000`, so a sub-second window would floor to 0s and reject every reading.
/// `expected_feed_id` must be exactly 32 bytes (Pyth price identifier).
public(package) fun new_oracle(
    max_staleness_ms: u64,
    expected_feed_id: vector<u8>,
    ctx: &mut TxContext,
): RiskOracle {
    assert!(max_staleness_ms >= 1000, EBadConfig);
    assert!(expected_feed_id.length() == 32, EBadConfig);
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

/// Production constructor for `PriceReading` — the ONLY non-test mint path.
/// `public(package)` so only in-package callers (`pyth_adapter`, fed by a verified
/// Pyth read of the bound feed) can mint one. See PriceReading's TRUST INVARIANT.
public(package) fun new_price_reading(conf_bps: u16, publish_ts_ms: u64): PriceReading {
    PriceReading { conf_bps, publish_ts_ms }
}

/// Share a freshly-created oracle. `RiskOracle` has `key` only (no `store`), so
/// `transfer::share_object` can only be called from this defining module — this
/// is the seam `admin::register_market` uses after binding caps/policy to the
/// oracle's id.
public(package) fun share_oracle(oracle: RiskOracle) {
    transfer::share_object(oracle);
}

// === Read-only helpers (frontend / off-chain executor preflight) ===

public fun is_active(oracle: &RiskOracle): bool { oracle.active }
public fun latest_score_bps(oracle: &RiskOracle): u16 { oracle.latest_score_bps }
public fun latest_score_ts_ms(oracle: &RiskOracle): u64 { oracle.latest_score_ts_ms }
public fun current_nonce(oracle: &RiskOracle): u64 { oracle.nonce }
public fun max_staleness_ms(oracle: &RiskOracle): u64 { oracle.max_staleness_ms }
public fun expected_feed_id(oracle: &RiskOracle): vector<u8> { oracle.expected_feed_id }
public fun reading_conf_bps(r: &PriceReading): u16 { r.conf_bps }
public fun reading_publish_ts_ms(r: &PriceReading): u64 { r.publish_ts_ms }

// === The write path ===

/// Authenticate, freshness-check, then apply an off-chain risk decision.
///
/// Validation order (fail before any irreversible state change — Rule 12):
///   0. kill switch: `oracle.active`
///   1. authorization double-bind: cap→oracle AND policy→oracle
///   2. replay: `nonce` strictly greater than the last accepted nonce
///   3. freshness: reading not future-dated AND within `max_staleness_ms`
///   4. confidence: `reading.conf_bps <= policy.max_conf_bps`
/// Only then: bump oracle state → emit `ScorePosted` → `policy::apply_decision`
/// (which performs the B3 rate-limit / MAX_PENDING / snapshot / write / emit).
public fun post_score_and_apply<M>(
    oracle: &mut RiskOracle,
    policy: &mut RiskPolicy<M>,
    cap: &RiskOraclePublisherCap,
    score_bps: u16,
    decision: Decision,
    reading: PriceReading,
    nonce: u64,
    clock: &Clock,
) {
    // 0. Kill switch — checked first so a paused oracle reveals nothing else.
    assert!(oracle.active, EOraclePaused);

    // 1. Authorization double-bind (anti-spoof, A1 apply leg). The cap proves the
    //    signer may post to THIS oracle; the policy binding proves this oracle
    //    governs THIS market's policy. A leaked publisher key for oracle A cannot
    //    be pointed at market B's policy.
    let oracle_id = object::id(oracle);
    assert!(caps::publisher_oracle_id(cap) == oracle_id, EWrongOracle);
    assert!(policy::bound_oracle_id(policy) == oracle_id, EWrongOracle);

    // 2. Replay protection (threat #2): strictly increasing nonce.
    assert!(nonce > oracle.nonce, EReplay);

    // 3. Freshness (threat #4). Reject future-dated readings (clock skew / spoof)
    //    and anything older than the staleness window. On failure the executor
    //    must NOT loosen — the policy simply keeps its last (more conservative)
    //    stance, which is the safe default.
    let now = clock.timestamp_ms();
    assert!(reading.publish_ts_ms <= now, EStaleOracle);
    // Subtraction form (not `publish_ts + max_staleness`) so a large staleness
    // config can't overflow u64 and abort with an arithmetic error instead of
    // EStaleOracle. Safe: the assert above guarantees `now >= publish_ts_ms`.
    assert!(now - reading.publish_ts_ms <= oracle.max_staleness_ms, EStaleOracle);

    // 4. Confidence ceiling (threat #1 / D5): a blown-out Pyth confidence on a
    //    low-liquidity stable feed is exactly when an attacker would want to
    //    loosen. Reject wide-band prices regardless of direction.
    assert!(reading.conf_bps <= policy::max_conf_bps(policy), EConfTooWide);

    // Commit oracle state. Nonce is the durable replay guard; ts/score are audit.
    oracle.nonce = nonce;
    oracle.latest_score_bps = score_bps;
    oracle.latest_score_ts_ms = now;

    events::emit_score_posted(type_name::with_defining_ids<M>(), score_bps, now, nonce);

    // Delegate the policy mutation. apply_decision owns the B3 rate limit, the
    // MAX_PENDING gate, the revert snapshot, the write, and the ActionExecuted
    // event. Keeping that here would duplicate (and risk diverging from) policy's
    // invariants — Rule 8.
    policy::apply_decision(policy, decision, score_bps, clock);
}

// === Kill switch (B2 asymmetric stop/start) ===

/// Engage the kill switch. Any `EmergencyStopCap` holder (single signer, fast):
/// halts all `post_score_and_apply` until an `AdminCap` resume. Bound-oracle
/// checked so a stop cap for oracle A can't pause oracle B.
public fun pause_oracle(oracle: &mut RiskOracle, cap: &EmergencyStopCap, clock: &Clock, ctx: &TxContext) {
    assert!(caps::stop_oracle_id(cap) == object::id(oracle), EWrongOracle);
    oracle.active = false;
    events::emit_oracle_paused(object::id(oracle), ctx.sender(), clock.timestamp_ms());
}

/// Release the kill switch. Requires `AdminCap` (slow, multisig) — asymmetric
/// with pause by design (B2): cheap to stop, deliberate to restart.
///
/// Accepted centralization (codex review F2, 2026-05-30): `AdminCap` is the
/// GLOBAL root authority (spec §2.7) — it is NOT oracle-bound, so the 2-of-3 ops
/// multisig can resume any oracle. This is intentional: resume is a deliberate,
/// quorum-gated action, and a per-oracle resume cap would multiply key-management
/// surface for no security gain over the root multisig. Stop stays oracle-bound
/// (EmergencyStopCap) so a single hot wallet can't halt the wrong market.
public fun resume_oracle(oracle: &mut RiskOracle, _admin: &AdminCap, clock: &Clock, ctx: &TxContext) {
    oracle.active = true;
    events::emit_oracle_resumed(object::id(oracle), ctx.sender(), clock.timestamp_ms());
}

// === Test-only ===

#[test_only]
public(package) fun new_oracle_for_testing(max_staleness_ms: u64, ctx: &mut TxContext): RiskOracle {
    // 32-byte dummy feed id — keeps the existing 2-arg test call sites untouched.
    new_oracle(max_staleness_ms, x"00000000000000000000000000000000000000000000000000000000000000aa", ctx)
}

#[test_only]
public(package) fun new_price_reading_for_testing(conf_bps: u16, publish_ts_ms: u64): PriceReading {
    new_price_reading(conf_bps, publish_ts_ms)
}

#[test_only]
public(package) fun mint_publisher_cap_for_testing(oracle: &RiskOracle, ctx: &mut TxContext): RiskOraclePublisherCap {
    caps::new_publisher_cap(object::id(oracle), ctx)
}

#[test_only]
public(package) fun mint_stop_cap_for_testing(oracle: &RiskOracle, ctx: &mut TxContext): EmergencyStopCap {
    caps::new_stop_cap(object::id(oracle), ctx)
}

#[test_only]
public(package) fun mint_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    caps::new_admin_cap(ctx)
}
