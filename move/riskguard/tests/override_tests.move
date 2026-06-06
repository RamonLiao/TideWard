#[test_only]
module riskguard::override_tests;

use sui::clock::{Self, Clock};
use std::unit_test::{assert_eq, destroy};
use riskguard::policy::{Self, RiskPolicy};
use riskguard::caps::OverrideCap;
use riskguard::override;

// Test market witness (phantom tag).
public struct TEST_MKT {}

// Flags mirror policy.move (private there).
const F_BORROWS: u8 = 1 << 0;
const F_LIQ: u8     = 1 << 1;

const DEFAULT_LTV: u16 = 5_000;
const WINDOW_MS: u64   = 86_400_000; // 24h
const COOLDOWN_MS: u64 = 3_600_000;  // 1h
const REASON: u8       = 9;          // arbitrary override reason code

fun setup(ctx: &mut TxContext): (RiskPolicy<TEST_MKT>, OverrideCap<TEST_MKT>, Clock) {
    let oracle_id = object::id_from_address(@0xACE);
    let policy = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, oracle_id, ctx);
    let cap = policy::mint_override_for_testing<TEST_MKT>(&policy, ctx);
    let clock = clock::create_for_testing(ctx);
    (policy, cap, clock)
}

// === Happy path: force-tighten LTV ===

#[test]
fun force_tighten_ltv() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);

    override::force_protect(&mut policy, &cap, 3_000, 0, REASON, &clock, &ctx);

    assert_eq!(policy::current_ltv_cap(&policy), 3_000);
    assert_eq!(policy::current_flags(&policy), 0);
    assert_eq!(policy::pending_count(&policy), 1);

    destroy(clock);
    destroy(policy);
    destroy(cap);
}

// === Happy path: force-set a pause flag (LTV unchanged) ===

#[test]
fun force_set_flag() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);

    override::force_protect(&mut policy, &cap, DEFAULT_LTV, F_BORROWS, REASON, &clock, &ctx);

    assert_eq!(policy::current_ltv_cap(&policy), DEFAULT_LTV);
    assert!(policy::is_borrows_paused(&policy));
    assert_eq!(policy::pending_count(&policy), 1);

    destroy(clock);
    destroy(policy);
    destroy(cap);
}

// === Happy path: lower LTV AND add flags in one call ===

#[test]
fun force_combined() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);

    override::force_protect(&mut policy, &cap, 2_000, F_BORROWS | F_LIQ, REASON, &clock, &ctx);

    assert_eq!(policy::current_ltv_cap(&policy), 2_000);
    assert!(policy::is_borrows_paused(&policy));
    assert!(policy::is_liquidations_paused(&policy));

    destroy(clock);
    destroy(policy);
    destroy(cap);
}

// === Reject: raising LTV is not protective ===

#[test, expected_failure(abort_code = 23, location = riskguard::override)]
fun reject_loosen_ltv() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);
    override::force_protect(&mut policy, &cap, 6_000, 0, REASON, &clock, &ctx);
    abort
}

// === Reject: clearing a set flag is not protective ===

#[test, expected_failure(abort_code = 23, location = riskguard::override)]
fun reject_clear_flag() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);
    // set the flag first (valid)…
    override::force_protect(&mut policy, &cap, DEFAULT_LTV, F_BORROWS, REASON, &clock, &ctx);
    // …then try to clear it → ENotProtective
    override::force_protect(&mut policy, &cap, DEFAULT_LTV, 0, REASON, &clock, &ctx);
    abort
}

// === Reject: no-op (nothing changes) ===

#[test, expected_failure(abort_code = 24, location = riskguard::override)]
fun reject_noop() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);
    // default ltv + default flags(0) → no change
    override::force_protect(&mut policy, &cap, DEFAULT_LTV, 0, REASON, &clock, &ctx);
    abort
}

// === Reject: cap bound to a different policy (anti-spoof) ===

#[test, expected_failure(abort_code = 1001, location = riskguard::override)]
fun reject_wrong_cap() {
    let mut ctx = tx_context::dummy();
    let (mut policy, _cap, clock) = setup(&mut ctx);

    // A second, independent policy with its own cap.
    let other_oracle = object::id_from_address(@0xBEEF);
    let other = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, other_oracle, &mut ctx);
    let other_cap = policy::mint_override_for_testing<TEST_MKT>(&other, &mut ctx);

    // Using `other`'s cap on the first policy must abort EWrongPolicy.
    override::force_protect(&mut policy, &other_cap, 3_000, 0, REASON, &clock, &ctx);
    abort
}

// === Reject: reserved flag bit (structural check in policy.move) ===

#[test, expected_failure(abort_code = 22, location = riskguard::policy)]
fun reject_reserved_flag() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);
    // bit 4 (1<<4) is reserved; passes monotonic+noop, fails flag-mask in apply_override
    override::force_protect(&mut policy, &cap, DEFAULT_LTV, 1 << 4, REASON, &clock, &ctx);
    abort
}

// === Reject: pending queue full (MAX_PENDING gate in policy.move) ===

#[test, expected_failure(abort_code = 11, location = riskguard::policy)]
fun reject_when_pending_full() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);

    // 8 strictly-tightening overrides at t=0 (no prune; window not elapsed).
    let mut i = 0u16;
    while (i < 8) {
        override::force_protect(&mut policy, &cap, 4_999 - i, 0, REASON, &clock, &ctx);
        i = i + 1;
    };
    // 9th exceeds MAX_PENDING → ETooManyPending
    override::force_protect(&mut policy, &cap, 4_990, 0, REASON, &clock, &ctx);
    abort
}

// === Integration: an override is revertable via revert_action ===

#[test]
fun override_then_revert() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap, clock) = setup(&mut ctx);

    // Override: 5000 → 3000 + pause borrows (action_id 0).
    override::force_protect(&mut policy, &cap, 3_000, F_BORROWS, REASON, &clock, &ctx);
    assert_eq!(policy::current_ltv_cap(&policy), 3_000);
    assert_eq!(policy::pending_count(&policy), 1);

    // Revert it within the window → exact pre-image restored, snapshot cleared.
    policy::revert_action(&mut policy, &cap, 0, &clock, &ctx);
    assert_eq!(policy::current_ltv_cap(&policy), DEFAULT_LTV);
    assert_eq!(policy::current_flags(&policy), 0);
    assert_eq!(policy::pending_count(&policy), 0);

    destroy(clock);
    destroy(policy);
    destroy(cap);
}
