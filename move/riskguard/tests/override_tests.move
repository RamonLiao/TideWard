#[test_only]
module riskguard::override_tests;

use sui::clock::{Self, Clock};
use std::unit_test::{assert_eq, destroy};
use riskguard::policy::{Self, RiskPolicy};
use riskguard::caps::OverrideCap;
use riskguard::override;

// Test market witness (phantom tag).
public struct TEST_MKT {}

// Flags mirror policy.move (private there). Suppress unused warning; Task 4 uses these.
#[allow(unused_const)]
const F_BORROWS: u8 = 1 << 0;

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
