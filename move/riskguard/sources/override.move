/// DAO protective override — the human-driven counterpart to the oracle's
/// `post_score_and_apply`. Lets an `OverrideCap<M>` holder force a *more
/// protective* stance (lower LTV and/or add pause flags) immediately, bypassing
/// the oracle and the B3 loosen throttle.
///
/// Monotonic-protective by construction: an override may only tighten, never
/// loosen. This bounds a compromised `OverrideCap` to over-tightening (a DoS
/// that is recoverable via `policy::revert_action` or a fresh oracle score) —
/// it can never raise the LTV cap or clear a pause flag to enable bad borrows.
///
/// Boundary (architecture review M1): this module owns override *semantics*
/// (cap binding, monotonic check, no-op reject) using policy's public getters;
/// `policy::apply_override` owns the *storage mechanics* (snapshot, write, emit).
module riskguard::override;

use sui::clock::Clock;
use riskguard::caps::{Self, OverrideCap};
use riskguard::policy::{Self, RiskPolicy};

// Error codes. Mirror policy.move's numbering range (source of truth for the
// stable cross-component contract): policy uses 1-5,8,9,11,13,20,21,22,1001;
// pyth_adapter holds 30,31. 23/24 are declared here, their only use site, to
// avoid unused-const warnings in policy.move.
const EWrongPolicy: u64   = 1001; // cap not bound to this policy (anti-spoof)
const ENotProtective: u64 = 23;   // override would loosen (raise LTV / clear a flag)
const EOverrideNoop: u64  = 24;   // override changes nothing

/// DAO forces a protective stance on `policy`. `new_ltv_bps` must be <= the
/// current cap; `new_flags` must be a superset of the current flags (add only).
/// At least one must change. Snapshots the pre-image, so the DAO can unwind its
/// own panic-tighten via `policy::revert_action` within the revert window.
public fun force_protect<M>(
    policy: &mut RiskPolicy<M>,
    cap: &OverrideCap<M>,
    new_ltv_bps: u16,
    new_flags: u8,
    reason_code: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Anti-spoof (A1 runtime leg): this cap must be bound to THIS policy.
    assert!(caps::override_policy_id(cap) == object::id(policy), EWrongPolicy);

    let cur_ltv = policy::current_ltv_cap(policy);
    let cur_flags = policy::current_flags(policy);

    // Monotonic-protective: LTV may only drop; flags may only be added.
    // `cur_flags & new_flags == cur_flags` <=> every set bit in cur stays set.
    assert!(new_ltv_bps <= cur_ltv, ENotProtective);
    assert!(cur_flags & new_flags == cur_flags, ENotProtective);

    // Reject no-op so we never push an empty snapshot.
    assert!(new_ltv_bps != cur_ltv || new_flags != cur_flags, EOverrideNoop);

    policy::apply_override(policy, new_ltv_bps, new_flags, reason_code, clock, ctx);
}
