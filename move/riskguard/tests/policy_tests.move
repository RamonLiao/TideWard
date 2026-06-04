#[test_only]
module riskguard::policy_tests;

use sui::clock::{Self, Clock};
use std::unit_test::{assert_eq, destroy};
use riskguard::policy::{Self, RiskPolicy};

// Test market witness (phantom tag).
public struct TEST_MKT {}

// Flags mirror policy.move (private there).
const F_BORROWS: u8 = 1 << 0;
const F_LIQ: u8     = 1 << 1;

const DEFAULT_LTV: u16 = 5_000;
const WINDOW_MS: u64   = 86_400_000; // 24h
const COOLDOWN_MS: u64 = 3_600_000;  // 1h

const REASON_DEPEG: u8 = 1;

fun setup(ctx: &mut TxContext): (RiskPolicy<TEST_MKT>, Clock) {
    let oracle_id = object::id_from_address(@0xACE);
    let policy = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, oracle_id, ctx);
    let clock = clock::create_for_testing(ctx);
    (policy, clock)
}

// === Happy path: tighten + read ===

#[test]
fun tighten_then_read() {
    let mut ctx = tx_context::dummy();
    let (mut policy, clock) = setup(&mut ctx);

    let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d, 8_400, &clock);

    assert_eq!(policy::current_ltv_cap(&policy), 3_000);
    assert!(policy::is_borrows_paused(&policy));
    assert!(!policy::is_liquidations_paused(&policy));
    assert_eq!(policy::pending_count(&policy), 1);

    destroy(clock);
    destroy(policy);
}

// === Gate: borrow over current cap rejected ===

#[test, expected_failure(abort_code = 5, location = riskguard::policy)]
fun borrow_over_cap_rejected() {
    let mut ctx = tx_context::dummy();
    let (policy, clock) = setup(&mut ctx);
    // default cap 5000; request 6000 → ELtvExceeded
    policy::assert_borrow_allowed(&policy, 6_000, &clock);
    abort
}

// === Gate: paused borrows rejected ===

#[test, expected_failure(abort_code = 1, location = riskguard::policy)]
fun paused_borrow_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut policy, clock) = setup(&mut ctx);
    let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d, 8_400, &clock);
    policy::assert_borrow_allowed(&policy, 100, &clock); // under cap but paused → EBorrowsPaused
    abort
}

// === B3: loosening before cooldown rejected ===

#[test, expected_failure(abort_code = 13, location = riskguard::policy)]
fun loosen_too_soon() {
    let mut ctx = tx_context::dummy();
    let (mut policy, mut clock) = setup(&mut ctx);

    // tighten at t=0 (no cooldown on tightening)
    let d1 = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d1, 8_400, &clock);

    // loosen 1s later → raises ltv → loosening, cooldown not elapsed → abort
    clock::set_for_testing(&mut clock, 1_000);
    let d2 = policy::new_decision(5_000, 0, 0);
    policy::apply_decision(&mut policy, d2, 2_000, &clock);
    abort
}

// === B3: loosening after cooldown allowed ===

#[test]
fun loosen_after_cooldown() {
    let mut ctx = tx_context::dummy();
    let (mut policy, mut clock) = setup(&mut ctx);

    let d1 = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d1, 8_400, &clock);

    clock::set_for_testing(&mut clock, COOLDOWN_MS);
    let d2 = policy::new_decision(5_000, 0, 0);
    policy::apply_decision(&mut policy, d2, 2_000, &clock);

    assert_eq!(policy::current_ltv_cap(&policy), 5_000);
    assert!(!policy::is_borrows_paused(&policy));

    destroy(clock);
    destroy(policy);
}

// === Revert cascades and restores pre-image ===

#[test]
fun revert_cascades_to_baseline() {
    let mut ctx = tx_context::dummy();
    let (mut policy, mut clock) = setup(&mut ctx);

    // A0: 5000→3000, set borrows (id 0, t=0)
    let d1 = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d1, 8_400, &clock);
    // A1: 3000→2000, set borrows|liq (id 1, t=100) — both tightening, no cooldown
    clock::set_for_testing(&mut clock, 100);
    let d2 = policy::new_decision(2_000, F_BORROWS | F_LIQ, REASON_DEPEG);
    policy::apply_decision(&mut policy, d2, 9_000, &clock);
    assert_eq!(policy::pending_count(&policy), 2);

    // revert id 0 within window → cascade drops id 1 too, state back to baseline
    let cap = policy::mint_override_for_testing(&policy, &mut ctx);
    clock::set_for_testing(&mut clock, 200);
    policy::revert_action(&mut policy, &cap, 0, &clock, &ctx);

    assert_eq!(policy::current_ltv_cap(&policy), DEFAULT_LTV);
    assert_eq!(policy::current_flags(&policy), 0);
    assert_eq!(policy::pending_count(&policy), 0);

    destroy(cap);
    destroy(clock);
    destroy(policy);
}

// === Revert after window closed rejected ===

#[test, expected_failure(abort_code = 8, location = riskguard::policy)]
fun revert_window_closed() {
    let mut ctx = tx_context::dummy();
    let (mut policy, mut clock) = setup(&mut ctx);

    let d1 = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d1, 8_400, &clock);

    let cap = policy::mint_override_for_testing(&policy, &mut ctx);
    clock::set_for_testing(&mut clock, WINDOW_MS + 1);
    policy::revert_action(&mut policy, &cap, 0, &clock, &ctx); // ERevertWindowClosed
    destroy(cap);
    abort
}

// === Override cap bound to a different policy rejected (A1 runtime leg) ===

#[test, expected_failure(abort_code = 1001, location = riskguard::policy)]
fun wrong_policy_override_rejected() {
    let mut ctx = tx_context::dummy();
    let (policy_a, clock) = setup(&mut ctx);
    let oracle_id = object::id_from_address(@0xACE);
    let mut policy_b = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, oracle_id, &mut ctx);

    let cap_a = policy::mint_override_for_testing(&policy_a, &mut ctx);
    // cap bound to A, used on B → EWrongPolicy (id check is first)
    policy::revert_action(&mut policy_b, &cap_a, 0, &clock, &ctx);

    destroy(cap_a);
    destroy(clock);
    destroy(policy_a);
    destroy(policy_b);
    abort
}

// === MAX_PENDING gate ===

#[test, expected_failure(abort_code = 11, location = riskguard::policy)]
fun max_pending_enforced() {
    let mut ctx = tx_context::dummy();
    let (mut policy, clock) = setup(&mut ctx); // clock stays at t=0 → nothing prunes

    // 8 identical tightening applies fill pending (no loosen, no expiry)
    let mut i = 0u64;
    while (i < 8) {
        let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
        policy::apply_decision(&mut policy, d, 8_400, &clock);
        i = i + 1;
    };
    assert_eq!(policy::pending_count(&policy), 8);

    // 9th → ETooManyPending
    let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d, 8_400, &clock);
    abort
}

// === Config guard: zero loosen-cooldown rejected (red-team vector 5) ===

#[test, expected_failure(abort_code = 21, location = riskguard::policy)]
fun zero_cooldown_rejected() {
    let mut ctx = tx_context::dummy();
    let oracle_id = object::id_from_address(@0xACE);
    // min_loosen_interval_ms = 0 would disable the B3 throttle → EBadConfig
    let policy = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, WINDOW_MS, 0, oracle_id, &mut ctx);
    destroy(policy);
    abort
}

// === Expired snapshots are pruned, freeing a slot ===

#[test]
fun prune_frees_slot() {
    let mut ctx = tx_context::dummy();
    let (mut policy, mut clock) = setup(&mut ctx);

    let d1 = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d1, 8_400, &clock);
    assert_eq!(policy::pending_count(&policy), 1);

    // advance past window; next apply prunes the stale snapshot first
    clock::set_for_testing(&mut clock, WINDOW_MS + 1);
    let d2 = policy::new_decision(2_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d2, 8_400, &clock);

    assert_eq!(policy::pending_count(&policy), 1); // old pruned, new pushed

    destroy(clock);
    destroy(policy);
}

// === Red-team H1: near-MAX revert window must not overflow ===
// With the old `snap.ts_ms + revert_window` form this aborts with an arithmetic
// error; the subtraction form keeps the revert reachable. Locks the overflow fix.
#[test]
fun huge_revert_window_no_overflow() {
    let mut ctx = tx_context::dummy();
    let oracle_id = object::id_from_address(@0xACE);
    let max_u64: u64 = 18_446_744_073_709_551_615;
    // cooldown < window invariant holds; window = u64::MAX
    let mut policy = policy::new_for_testing<TEST_MKT>(DEFAULT_LTV, max_u64, COOLDOWN_MS, oracle_id, &mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);

    clock::set_for_testing(&mut clock, 1_000);
    let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
    policy::apply_decision(&mut policy, d, 8_400, &clock);

    // Revert far in the future: `now - ts` is fine; `ts + window` would have overflowed.
    let cap = policy::mint_override_for_testing(&policy, &mut ctx);
    clock::set_for_testing(&mut clock, 1_000_000_000);
    policy::revert_action(&mut policy, &cap, 0, &clock, &ctx);

    assert_eq!(policy::current_ltv_cap(&policy), DEFAULT_LTV);

    destroy(clock);
    destroy(policy);
    destroy(cap);
}

// === Red-team H2: Decision with a reserved flag bit is rejected ===
#[test, expected_failure(abort_code = 22, location = riskguard::policy)]
fun undefined_flag_bit_rejected() {
    // bit 4 (0x10) is reserved; new_decision must abort EInvalidFlags before
    // junk reaches the policy.
    let _d = policy::new_decision(3_000, 1u8 << 4, REASON_DEPEG);
    abort
}
