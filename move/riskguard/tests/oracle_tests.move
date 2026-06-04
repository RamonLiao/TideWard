#[test_only]
module riskguard::oracle_tests;

use sui::clock::{Self, Clock};
use std::unit_test::{assert_eq, destroy};
use riskguard::policy::{Self, RiskPolicy};
use riskguard::oracle::{Self, RiskOracle};
use riskguard::caps::{RiskOraclePublisherCap, AdminCap};

// Test market witness (phantom tag).
public struct TEST_MKT {}

const F_BORROWS: u8 = 1 << 0;

const DEFAULT_LTV: u16 = 5_000;
const WINDOW_MS: u64   = 86_400_000; // 24h
const COOLDOWN_MS: u64 = 3_600_000;  // 1h
const STALENESS_MS: u64 = 60_000;    // 60s (spec §9.5 hard ceiling)
const NOW: u64 = 1_000_000_000_000;  // arbitrary clock origin (> staleness)
const REASON_DEPEG: u8 = 1;

// Builds an oracle + a policy bound to it + a publisher cap bound to it + a clock
// pinned at NOW. Policy `max_conf_bps` defaults to 50 (policy::new_for_testing).
fun setup(ctx: &mut TxContext): (RiskOracle, RiskPolicy<TEST_MKT>, RiskOraclePublisherCap, Clock) {
    let oracle = oracle::new_oracle_for_testing(STALENESS_MS, ctx);
    let policy = policy::new_for_testing<TEST_MKT>(
        DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, object::id(&oracle), ctx,
    );
    let cap = oracle::mint_publisher_cap_for_testing(&oracle, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW);
    (oracle, policy, cap, clock)
}

// A tightening decision (lower LTV + set a pause flag) — never throttled by B3.
fun tighten_decision(): policy::Decision {
    policy::new_decision(3_000, F_BORROWS, REASON_DEPEG)
}

// fresh reading at NOW, tight confidence (<= 50)
fun fresh_reading(): oracle::PriceReading {
    oracle::new_price_reading_for_testing(40, NOW)
}

// === Happy path: authenticated, fresh post mutates policy + oracle state ===

#[test]
fun post_applies_and_updates_oracle() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), fresh_reading(), 1, &clock,
    );

    // Policy mutated via apply_decision.
    assert_eq!(policy::current_ltv_cap(&policy), 3_000);
    assert!(policy::is_borrows_paused(&policy));
    assert_eq!(policy::pending_count(&policy), 1);
    // Oracle state advanced.
    assert_eq!(oracle::current_nonce(&oracle), 1);
    assert_eq!(oracle::latest_score_bps(&oracle), 8_400);
    assert_eq!(oracle::latest_score_ts_ms(&oracle), NOW);

    destroy(cap); destroy(clock); destroy(policy); destroy(oracle);
}

// === Vector 5: post while paused is rejected (kill switch) ===

#[test, expected_failure(abort_code = 14, location = riskguard::oracle)]
fun paused_post_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);
    let stop = oracle::mint_stop_cap_for_testing(&oracle, &mut ctx);

    oracle::pause_oracle(&mut oracle, &stop, &clock, &ctx);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), fresh_reading(), 1, &clock,
    );
    abort
}

// === Kill switch is asymmetric: pause (stop cap) then resume (admin) re-enables ===

#[test]
fun pause_then_resume_allows_post() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);
    let stop = oracle::mint_stop_cap_for_testing(&oracle, &mut ctx);
    let admin: AdminCap = oracle::mint_admin_cap_for_testing(&mut ctx);

    oracle::pause_oracle(&mut oracle, &stop, &clock, &ctx);
    assert!(!oracle::is_active(&oracle));
    oracle::resume_oracle(&mut oracle, &admin, &clock, &ctx);
    assert!(oracle::is_active(&oracle));

    // Post now succeeds.
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), fresh_reading(), 1, &clock,
    );
    assert_eq!(oracle::current_nonce(&oracle), 1);

    destroy(stop); destroy(admin); destroy(cap); destroy(clock); destroy(policy); destroy(oracle);
}

// === Vector 1: replay — non-increasing nonce rejected ===

#[test, expected_failure(abort_code = 7, location = riskguard::oracle)]
fun replay_same_nonce_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, mut clock) = setup(&mut ctx);

    // First post at nonce 5 succeeds.
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(),
        oracle::new_price_reading_for_testing(40, NOW), 5, &clock,
    );
    // Advance clock so freshness isn't the failure cause; replay nonce 5.
    clock.set_for_testing(NOW + 1_000);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(),
        oracle::new_price_reading_for_testing(40, NOW + 1_000), 5, &clock,
    );
    abort
}

// === Vector 2: stale price (older than staleness window) rejected ===

#[test, expected_failure(abort_code = 6, location = riskguard::oracle)]
fun stale_reading_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    // publish_ts one ms beyond the staleness window.
    let stale = oracle::new_price_reading_for_testing(40, NOW - STALENESS_MS - 1);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), stale, 1, &clock,
    );
    abort
}

// === Vector 2b: future-dated reading rejected (clock skew / spoof) ===

#[test, expected_failure(abort_code = 6, location = riskguard::oracle)]
fun future_dated_reading_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    let future = oracle::new_price_reading_for_testing(40, NOW + 1);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), future, 1, &clock,
    );
    abort
}

// Boundary: a reading exactly at the staleness edge is still accepted.
#[test]
fun staleness_edge_accepted() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    let edge = oracle::new_price_reading_for_testing(40, NOW - STALENESS_MS); // now == publish + staleness
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), edge, 1, &clock,
    );
    assert_eq!(oracle::current_nonce(&oracle), 1);

    destroy(cap); destroy(clock); destroy(policy); destroy(oracle);
}

// === Vector 3: confidence wider than policy.max_conf_bps rejected ===

#[test, expected_failure(abort_code = 10, location = riskguard::oracle)]
fun wide_confidence_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    // policy max_conf_bps default = 50; reading 51 → EConfTooWide.
    let wide = oracle::new_price_reading_for_testing(51, NOW);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), wide, 1, &clock,
    );
    abort
}

// === Vector 4a: publisher cap bound to a DIFFERENT oracle rejected ===

#[test, expected_failure(abort_code = 12, location = riskguard::oracle)]
fun cap_for_wrong_oracle_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, clock) = setup(&mut ctx);

    // A second oracle and a cap bound to IT, used against the first oracle.
    let other = oracle::new_oracle_for_testing(STALENESS_MS, &mut ctx);
    let wrong_cap = oracle::mint_publisher_cap_for_testing(&other, &mut ctx);
    destroy(cap); destroy(other);

    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &wrong_cap, 8_400, tighten_decision(), fresh_reading(), 1, &clock,
    );
    abort
}

// === Vector 4b: policy bound to a DIFFERENT oracle rejected ===

#[test, expected_failure(abort_code = 12, location = riskguard::oracle)]
fun policy_bound_to_wrong_oracle_rejected() {
    let mut ctx = tx_context::dummy();
    let oracle = oracle::new_oracle_for_testing(STALENESS_MS, &mut ctx);
    let cap = oracle::mint_publisher_cap_for_testing(&oracle, &mut ctx);
    // Policy bound to a bogus oracle id, not this oracle.
    let mut policy = policy::new_for_testing<TEST_MKT>(
        DEFAULT_LTV, WINDOW_MS, COOLDOWN_MS, object::id_from_address(@0xBAD), &mut ctx,
    );
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW);
    let mut oracle = oracle;

    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 8_400, tighten_decision(), fresh_reading(), 1, &clock,
    );
    abort
}

// === Stop cap bound to a different oracle cannot pause this one ===

#[test, expected_failure(abort_code = 12, location = riskguard::oracle)]
fun stop_cap_for_wrong_oracle_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, _policy, _cap, clock) = setup(&mut ctx);

    let other = oracle::new_oracle_for_testing(STALENESS_MS, &mut ctx);
    let wrong_stop = oracle::mint_stop_cap_for_testing(&other, &mut ctx);
    destroy(other);

    oracle::pause_oracle(&mut oracle, &wrong_stop, &clock, &ctx);
    abort
}

// === Constructor guard: zero staleness window rejected ===

#[test, expected_failure(abort_code = 21, location = riskguard::oracle)]
fun zero_staleness_rejected() {
    let mut ctx = tx_context::dummy();
    let oracle = oracle::new_oracle_for_testing(0, &mut ctx);
    destroy(oracle);
}

// === Constructor guard: feed id must be exactly 32 bytes (Pyth identifier) ===
#[test, expected_failure(abort_code = 21, location = riskguard::oracle)]
fun bad_feed_id_length_aborts() {
    let mut ctx = tx_context::dummy();
    let oracle = oracle::new_oracle(60_000, x"00aa", &mut ctx); // 2 bytes, not 32
    destroy(oracle);
}

// === Monkey/integration: policy's B3 cooldown fires THROUGH the oracle path ===
// A loosening decision posted within the cooldown must abort with policy's
// ELoosenTooSoon (13), proving oracle delegates the rate limit, not bypasses it.
#[test, expected_failure(abort_code = 13, location = riskguard::policy)]
fun loosen_within_cooldown_rejected_via_oracle() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, mut clock) = setup(&mut ctx);

    // Loosen #1 raises LTV 5000→6000. last_loosen_ts_ms was 0 and NOW >> cooldown,
    // so it's accepted and stamps last_loosen_ts_ms = NOW.
    let loosen1 = policy::new_decision(6_000, 0, REASON_DEPEG);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 4_000, loosen1, fresh_reading(), 1, &clock,
    );
    // Loosen #2 raises 6000→7000 only 1s later, inside the 1h cooldown → reject.
    clock.set_for_testing(NOW + 1_000); // << COOLDOWN_MS after loosen #1
    let loosen2 = policy::new_decision(7_000, 0, REASON_DEPEG);
    oracle::post_score_and_apply(
        &mut oracle, &mut policy, &cap, 3_000, loosen2,
        oracle::new_price_reading_for_testing(40, NOW + 1_000), 2, &clock,
    );
    abort
}

// === Monkey/integration: MAX_PENDING (8) enforced THROUGH the oracle path ===
// 8 distinct posts fill pending_actions; the 9th aborts with policy's
// ETooManyPending (11). Each post is a non-loosening no-op write (same stance),
// nonce strictly increasing, clock advanced < revert window so nothing prunes.
#[test, expected_failure(abort_code = 11, location = riskguard::policy)]
fun max_pending_enforced_via_oracle() {
    let mut ctx = tx_context::dummy();
    let (mut oracle, mut policy, cap, mut clock) = setup(&mut ctx);

    let mut i = 0u64;
    while (i < 9) {
        let t = NOW + i; // monotonic, all within 24h window → no pruning
        clock.set_for_testing(t);
        // Same LTV/flags each time: not loosening (no cooldown), still snapshots.
        let d = policy::new_decision(3_000, F_BORROWS, REASON_DEPEG);
        oracle::post_score_and_apply(
            &mut oracle, &mut policy, &cap, 8_400, d,
            oracle::new_price_reading_for_testing(40, t), i + 1, &clock,
        );
        i = i + 1;
    };
    abort
}
