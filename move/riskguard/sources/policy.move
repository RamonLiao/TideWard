/// RiskGuard per-market policy object — "the gate".
///
/// `RiskPolicy<phantom M>` is a shared object holding the *current* risk stance
/// for one market (LTV cap + per-action pause flags) plus the *minimal* state
/// needed to revert recent actions (`pending_actions` snapshots, bounded).
///
/// Design anchors (tasks/notes.md):
///   - Policy-object-as-gate: lenders call `assert_*_allowed` in their entry fns.
///   - Per-market `phantom M`: compile-time market isolation; reads are
///     parallel-safe (`&` immutable, no consensus contention).
///   - Events = audit trail; on-chain object stores only revert-critical state.
///   - Asymmetric rate limit (B3): tightening is free, loosening is throttled.
///
/// Deviation from spec §2.4 (Rule 7, confirmed 2026-05-30): `post_score_and_apply`
/// does NOT live here. It needs `&mut RiskOracle` + `RiskOraclePublisherCap`,
/// which would force a `policy → oracle` dependency and break the DAG (oracle
/// already depends on policy). Instead this module exposes
/// `public(package) apply_decision`, which `oracle::post_score_and_apply` calls
/// after it has validated the cap / freshness / nonce. `apply_decision` owns the
/// policy-state mutation: snapshot, rate limit, MAX_PENDING gate, flag/LTV write.
module riskguard::policy;

use sui::clock::Clock;
use std::type_name;
use riskguard::caps::{Self, OverrideCap};
use riskguard::events;

// === Flag bitfield (notes.md cheat sheet) ===
const FLAG_BORROWS_PAUSED: u8      = 1 << 0;
const FLAG_LIQUIDATIONS_PAUSED: u8 = 1 << 1;
const FLAG_DEPOSITS_PAUSED: u8     = 1 << 2;
const FLAG_WITHDRAWS_PAUSED: u8    = 1 << 3;

// === ActionSnapshot kinds (descriptive metadata for the indexer) ===
const KIND_LTV_CUT: u8  = 0;
const KIND_FLAG_SET: u8 = 1;
const KIND_COMBINED: u8 = 2;

// === Bounds ===
const MAX_PENDING: u64 = 8;
const MAX_BPS: u16 = 10_000; // 100.00%

// === Errors ===
// Module-local: Move has no cross-module `const`. Kept as plain `u64` with the
// exact values from spec §2.6 (NOT `#[error]`): the off-chain executor/indexer
// treat these numbers as a stable cross-component contract, and `#[error]` +
// private const breaks `expected_failure(abort_code = ...)` in sibling test
// modules. Naming is EPascalCase per Move 2024 convention.
const EBorrowsPaused: u64       = 1;
const ELiquidationsPaused: u64  = 2;
const EDepositsPaused: u64      = 3;
const EWithdrawsPaused: u64     = 4;
const ELtvExceeded: u64         = 5;
const ERevertWindowClosed: u64 = 8;
const EUnknownAction: u64       = 9;
const ETooManyPending: u64     = 11;
const ELoosenTooSoon: u64      = 13;
const EInvalidBps: u64          = 20;
const EBadConfig: u64           = 21;
const EInvalidFlags: u64        = 22;  // Decision sets an undefined (reserved) flag bit
const EWrongPolicy: u64         = 1001;

// Mask of defined pause-flag bits; bits 4..7 are reserved and must stay zero.
const KNOWN_FLAGS: u8 = FLAG_BORROWS_PAUSED | FLAG_LIQUIDATIONS_PAUSED | FLAG_DEPOSITS_PAUSED | FLAG_WITHDRAWS_PAUSED;

// === Core objects ===

public struct RiskPolicy<phantom M> has key, store {
    id: UID,
    ltv_bps: u16,                            // current LTV cap (e.g. 5000 = 50%)
    ltv_default_bps: u16,                    // baseline restored on full revert
    flags: u8,                               // pause bitfield
    revert_window_ms: u64,                   // how long an action stays revertable
    min_loosen_interval_ms: u64,             // cooldown applied to loosening only
    last_loosen_ts_ms: u64,                  // last accepted loosen (rate limit)
    max_conf_bps: u16,                       // Pyth confidence ceiling (read by oracle)
    oracle_id: ID,                           // bound RiskOracle (checked by oracle)
    next_action_id: u64,
    pending_actions: vector<ActionSnapshot>, // bounded by MAX_PENDING
    reserved: vector<u8>,                    // §2.8 future-proofing extension field
}

public struct ActionSnapshot has store, copy, drop {
    action_id: u64,
    kind: u8,
    prev_ltv_bps: u16,
    prev_flags: u8,
    reason_code: u8,
    ts_ms: u64,
}

/// Off-chain executor's decision payload. `copy, drop` + a public constructor
/// so it can be built in a PTB and handed to `oracle::post_score_and_apply`.
public struct Decision has copy, drop {
    new_ltv_bps: u16,
    new_flags: u8,
    reason_code: u8,
}

public fun new_decision(new_ltv_bps: u16, new_flags: u8, reason_code: u8): Decision {
    assert!(new_ltv_bps <= MAX_BPS, EInvalidBps);
    // Reject undefined flag bits: a reserved bit set here would persist into the
    // policy (no gate reads it) and confuse off-chain flag decoders. Constrain at
    // the constructor so a Decision can never carry junk into apply_decision.
    assert!(new_flags & (KNOWN_FLAGS ^ 0xFFu8) == 0, EInvalidFlags);
    Decision { new_ltv_bps, new_flags, reason_code }
}

// === Construction (package-internal; admin.move wraps with AdminCap gate) ===

/// Create a market policy. `ltv_bps` starts at the default baseline.
/// Invariant (notes.md): `min_loosen_interval_ms < revert_window_ms` — a loosen
/// must be possible within an action's revert window, else recovery deadlocks.
public(package) fun new<M>(
    ltv_default_bps: u16,
    revert_window_ms: u64,
    min_loosen_interval_ms: u64,
    max_conf_bps: u16,
    oracle_id: ID,
    ctx: &mut TxContext,
): RiskPolicy<M> {
    assert!(ltv_default_bps <= MAX_BPS, EInvalidBps);
    // Confidence ceiling must be a sane bps value. Without this an admin fat-finger
    // (e.g. 60000) leaves oracle's `conf_bps <= max_conf_bps` gate toothless, since
    // PriceReading.conf_bps is also u16 and would never exceed such a ceiling.
    assert!(max_conf_bps <= MAX_BPS, EInvalidBps);
    // min_loosen must be > 0 (else B3 throttle is disabled) and < revert_window
    // (else a loosen can't fit inside an action's revert window → recovery deadlock).
    assert!(min_loosen_interval_ms > 0, EBadConfig);
    assert!(min_loosen_interval_ms < revert_window_ms, EBadConfig);
    RiskPolicy<M> {
        id: object::new(ctx),
        ltv_bps: ltv_default_bps,
        ltv_default_bps,
        flags: 0,
        revert_window_ms,
        min_loosen_interval_ms,
        last_loosen_ts_ms: 0,
        max_conf_bps,
        oracle_id,
        next_action_id: 0,
        pending_actions: vector[],
        reserved: vector[],
    }
}

// === Lender-facing gates (per-action, opt-in) ===
//
// `clock` is kept in every gate signature for ABI stability: oracle-freshness
// coupling (assert_oracle_fresh) will be paired here in v1, and lenders already
// thread a `Clock` through their entry fns. Unused today — hence `_clock`.

public fun assert_borrow_allowed<M>(policy: &RiskPolicy<M>, requested_ltv_bps: u16, _clock: &Clock) {
    assert!(policy.flags & FLAG_BORROWS_PAUSED == 0, EBorrowsPaused);
    assert!(requested_ltv_bps <= policy.ltv_bps, ELtvExceeded);
}

public fun assert_liquidate_allowed<M>(policy: &RiskPolicy<M>, _clock: &Clock) {
    assert!(policy.flags & FLAG_LIQUIDATIONS_PAUSED == 0, ELiquidationsPaused);
}

public fun assert_deposit_allowed<M>(policy: &RiskPolicy<M>, _clock: &Clock) {
    assert!(policy.flags & FLAG_DEPOSITS_PAUSED == 0, EDepositsPaused);
}

public fun assert_withdraw_allowed<M>(policy: &RiskPolicy<M>, _clock: &Clock) {
    assert!(policy.flags & FLAG_WITHDRAWS_PAUSED == 0, EWithdrawsPaused);
}

// === Read-only helpers (off-chain health calcs & frontend) ===

public fun current_ltv_cap<M>(policy: &RiskPolicy<M>): u16 { policy.ltv_bps }
public fun current_flags<M>(policy: &RiskPolicy<M>): u8 { policy.flags }
public fun is_borrows_paused<M>(policy: &RiskPolicy<M>): bool { policy.flags & FLAG_BORROWS_PAUSED != 0 }
public fun is_liquidations_paused<M>(policy: &RiskPolicy<M>): bool { policy.flags & FLAG_LIQUIDATIONS_PAUSED != 0 }
public fun is_deposits_paused<M>(policy: &RiskPolicy<M>): bool { policy.flags & FLAG_DEPOSITS_PAUSED != 0 }
public fun is_withdraws_paused<M>(policy: &RiskPolicy<M>): bool { policy.flags & FLAG_WITHDRAWS_PAUSED != 0 }
public fun pending_count<M>(policy: &RiskPolicy<M>): u64 { policy.pending_actions.length() }
public fun bound_oracle_id<M>(policy: &RiskPolicy<M>): ID { policy.oracle_id }
public fun max_conf_bps<M>(policy: &RiskPolicy<M>): u16 { policy.max_conf_bps }

// === State mutation (called by oracle::post_score_and_apply) ===

/// Apply a validated `Decision` to the policy. The caller (oracle) is
/// responsible for cap/active/nonce/staleness/confidence checks BEFORE this.
///
/// Steps: prune expired snapshots → MAX_PENDING gate → loosen rate limit →
/// push snapshot of pre-image → write new LTV/flags → emit `ActionExecuted`.
public(package) fun apply_decision<M>(
    policy: &mut RiskPolicy<M>,
    decision: Decision,
    score_bps: u16,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();

    // 1. Drop snapshots whose revert window has closed (frees pending slots).
    prune_expired(policy, now);

    // 2. Bound pending state (anti-griefing, A2).
    assert!(policy.pending_actions.length() < MAX_PENDING, ETooManyPending);

    let prev_ltv = policy.ltv_bps;
    let prev_flags = policy.flags;

    // 3. Asymmetric rate limit (B3): any relaxation is throttled; tightening is free.
    //    Loosening = raising the LTV cap OR clearing any pause flag.
    if (is_loosening(prev_ltv, prev_flags, &decision)) {
        assert!(now >= policy.last_loosen_ts_ms + policy.min_loosen_interval_ms, ELoosenTooSoon);
        policy.last_loosen_ts_ms = now;
    };

    // 4. Snapshot the pre-image so the DAO can revert within the window.
    let action_id = policy.next_action_id;
    let kind = classify(prev_ltv, prev_flags, &decision);
    policy.pending_actions.push_back(ActionSnapshot {
        action_id,
        kind,
        prev_ltv_bps: prev_ltv,
        prev_flags,
        reason_code: decision.reason_code,
        ts_ms: now,
    });
    policy.next_action_id = action_id + 1;

    // 5. Apply.
    policy.ltv_bps = decision.new_ltv_bps;
    policy.flags = decision.new_flags;

    // 6. Audit.
    events::emit_action_executed(
        type_name::with_defining_ids<M>(),
        action_id,
        kind,
        prev_ltv,
        decision.new_ltv_bps,
        score_bps,
        now,
    );
}

// === Revert (DAO OverrideCap, within window) ===

/// Revert `action_id` and every action layered on top of it (cascade): a later
/// action's `prev_*` was captured relative to this one's effect, so restoring
/// only `action_id`'s pre-image and dropping the tail rewinds to the exact state
/// before `action_id` ever ran. Does NOT touch `last_loosen_ts_ms` (B3): a
/// revert is not a loosen and must not reset the cooldown clock.
public fun revert_action<M>(
    policy: &mut RiskPolicy<M>,
    cap: &OverrideCap<M>,
    action_id: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Anti-spoof (A1 runtime leg): this cap must be bound to THIS policy.
    assert!(caps::override_policy_id(cap) == object::id(policy), EWrongPolicy);

    let n = policy.pending_actions.length();
    let mut idx = n; // sentinel = not found
    let mut i = 0;
    while (i < n) {
        if (policy.pending_actions[i].action_id == action_id) { idx = i; break };
        i = i + 1;
    };
    assert!(idx < n, EUnknownAction);

    let snap = &policy.pending_actions[idx];
    let now = clock.timestamp_ms();
    // Subtraction form (not `snap.ts_ms + revert_window`) so an admin-set window
    // near u64::MAX can't overflow and abort with an arithmetic error instead of
    // ERevertWindowClosed. Safe: the snapshot was taken in the past and the clock
    // is monotonic, so `now >= snap.ts_ms`. Mirrors oracle.move's staleness guard.
    assert!(now - snap.ts_ms <= policy.revert_window_ms, ERevertWindowClosed);

    // Restore pre-image of the earliest reverted action.
    policy.ltv_bps = snap.prev_ltv_bps;
    policy.flags = snap.prev_flags;

    // Cascade: drop [idx .. n). Snapshots are append-ordered, so pop_back to idx.
    while (policy.pending_actions.length() > idx) {
        policy.pending_actions.pop_back();
    };

    events::emit_action_reverted(type_name::with_defining_ids<M>(), action_id, ctx.sender(), now);
}

// === Internal helpers ===

/// Loosening = the decision removes protection vs the current state:
/// raises the LTV cap, or clears (un-sets) any currently-set pause flag.
fun is_loosening(prev_ltv: u16, prev_flags: u8, decision: &Decision): bool {
    let raises_ltv = decision.new_ltv_bps > prev_ltv;
    // Bits set in prev but cleared in new = protections being removed.
    // Move has no unary bitwise NOT for integers; xor with 0xFF inverts u8.
    let cleared_flags = prev_flags & (decision.new_flags ^ 0xFFu8);
    raises_ltv || cleared_flags != 0
}

fun classify(prev_ltv: u16, prev_flags: u8, decision: &Decision): u8 {
    let ltv_changed = decision.new_ltv_bps != prev_ltv;
    let flags_changed = decision.new_flags != prev_flags;
    if (ltv_changed && flags_changed) KIND_COMBINED
    else if (flags_changed) KIND_FLAG_SET
    else KIND_LTV_CUT
}

/// Snapshots are append-ordered by `ts_ms` (clock is monotonic), so all expired
/// entries are a prefix — remove from the front until we hit a live one.
fun prune_expired<M>(policy: &mut RiskPolicy<M>, now: u64) {
    while (!policy.pending_actions.is_empty()) {
        let front = &policy.pending_actions[0];
        // Subtraction form (overflow-safe, see revert_action). `now >= front.ts_ms`:
        // snapshots are pushed with the current clock, which is monotonic.
        if (now - front.ts_ms > policy.revert_window_ms) {
            policy.pending_actions.remove(0);
        } else {
            break
        }
    }
}

// === Test-only accessors ===

#[test_only]
public(package) fun new_for_testing<M>(
    ltv_default_bps: u16,
    revert_window_ms: u64,
    min_loosen_interval_ms: u64,
    oracle_id: ID,
    ctx: &mut TxContext,
): RiskPolicy<M> {
    new<M>(ltv_default_bps, revert_window_ms, min_loosen_interval_ms, 50, oracle_id, ctx)
}

#[test_only]
public(package) fun mint_override_for_testing<M>(policy: &RiskPolicy<M>, ctx: &mut TxContext): OverrideCap<M> {
    caps::new_override_cap<M>(object::id(policy), ctx)
}
