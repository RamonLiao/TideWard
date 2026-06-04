#[test_only]
module riskguard::admin_tests;

use sui::test_scenario as ts;
use sui::clock;
use std::unit_test::assert_eq;
use riskguard::admin;
use riskguard::caps::{Self, AdminCap, RiskOraclePublisherCap, EmergencyStopCap, OverrideCap};
use riskguard::policy::{Self, RiskPolicy};
use riskguard::oracle::RiskOracle;

// Two market witnesses to prove per-market isolation.
public struct BTC_MKT {}
public struct ETH_MKT {}

// Distinct operational roles (threat-model separation).
const DEPLOYER: address  = @0xAD;   // ops multisig (holds AdminCap)
const PUBLISHER: address = @0xA11CE; // KMS publisher
const STOPPER: address   = @0xB0B;   // on-call hot wallet
const DAO: address       = @0xDA0;   // per-market DAO multisig

const LTV: u16       = 5_000;
const WINDOW: u64    = 86_400_000; // 24h
const COOLDOWN: u64  = 3_600_000;  // 1h
const MAX_CONF: u16  = 50;
const STALENESS: u64 = 60_000;     // 60s
const FEED: vector<u8> = x"00000000000000000000000000000000000000000000000000000000000000aa"; // 32-byte dummy Pyth feed id

// === Genesis: init mints exactly one AdminCap to the deployer ===

#[test]
fun init_mints_single_admin_cap_to_deployer() {
    let mut sc = ts::begin(DEPLOYER);
    admin::init_for_testing(sc.ctx());

    sc.next_tx(DEPLOYER);
    assert!(ts::has_most_recent_for_sender<AdminCap>(&sc));
    let cap = ts::take_from_sender<AdminCap>(&sc);
    // Exactly one: after taking it, none remain for the sender.
    assert!(!ts::has_most_recent_for_sender<AdminCap>(&sc));
    ts::return_to_sender(&sc, cap);
    sc.end();
}

// === Happy path: register shares policy+oracle, distributes 3 caps, emits 1 event ===

#[test]
fun register_distributes_caps_and_shares_objects() {
    let mut sc = ts::begin(DEPLOYER);
    admin::init_for_testing(sc.ctx());

    sc.next_tx(DEPLOYER);
    let admin_cap = ts::take_from_sender<AdminCap>(&sc);
    let clock = clock::create_for_testing(sc.ctx());
    admin::register_market<BTC_MKT>(
        &admin_cap, LTV, WINDOW, COOLDOWN, MAX_CONF, STALENESS,
        FEED,
        PUBLISHER, STOPPER, DAO, &clock, sc.ctx(),
    );
    ts::return_to_sender(&sc, admin_cap);
    clock.destroy_for_testing();

    // Exactly one user event (MarketRegistered) — policy/oracle/cap creation emit nothing.
    let effects = sc.next_tx(DEPLOYER);
    assert_eq!(ts::num_user_events(&effects), 1);

    // Both objects are shared and reachable.
    let policy = ts::take_shared<RiskPolicy<BTC_MKT>>(&sc);
    let oracle = ts::take_shared<RiskOracle>(&sc);
    let oracle_id = object::id(&oracle);
    let policy_id = object::id(&policy);

    // Policy is bound to the freshly-created oracle (no external id input).
    assert_eq!(policy::bound_oracle_id(&policy), oracle_id);

    // Each cap landed at its role address AND is bound to the right object.
    let pcap = ts::take_from_address<RiskOraclePublisherCap>(&sc, PUBLISHER);
    let scap = ts::take_from_address<EmergencyStopCap>(&sc, STOPPER);
    let ocap = ts::take_from_address<OverrideCap<BTC_MKT>>(&sc, DAO);
    assert_eq!(caps::publisher_oracle_id(&pcap), oracle_id);
    assert_eq!(caps::stop_oracle_id(&scap), oracle_id);
    assert_eq!(caps::override_policy_id(&ocap), policy_id);

    ts::return_to_address(PUBLISHER, pcap);
    ts::return_to_address(STOPPER, scap);
    ts::return_to_address(DAO, ocap);
    ts::return_shared(policy);
    ts::return_shared(oracle);
    sc.end();
}

// === Config guard propagates: bad policy config aborts the whole registration ===
// min_loosen_interval_ms = 0 → policy::new EBadConfig (21). Proves register_market
// doesn't bypass policy's constructor invariants, and the tx rolls back atomically.

#[test, expected_failure(abort_code = 21, location = riskguard::policy)]
fun register_with_zero_cooldown_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    admin::init_for_testing(sc.ctx());

    sc.next_tx(DEPLOYER);
    let admin_cap = ts::take_from_sender<AdminCap>(&sc);
    let clock = clock::create_for_testing(sc.ctx());
    admin::register_market<BTC_MKT>(
        &admin_cap, LTV, WINDOW, 0, MAX_CONF, STALENESS,
        FEED,
        PUBLISHER, STOPPER, DAO, &clock, sc.ctx(),
    );
    abort
}

// === Config guard: out-of-range confidence ceiling aborts (codex F1) ===
// max_conf_bps > MAX_BPS (10_000) → policy::new EInvalidBps (20). Without the
// guard a fat-fingered ceiling would silently disable oracle's confidence gate.

#[test, expected_failure(abort_code = 20, location = riskguard::policy)]
fun register_with_excessive_max_conf_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    admin::init_for_testing(sc.ctx());

    sc.next_tx(DEPLOYER);
    let admin_cap = ts::take_from_sender<AdminCap>(&sc);
    let clock = clock::create_for_testing(sc.ctx());
    admin::register_market<BTC_MKT>(
        &admin_cap, LTV, WINDOW, COOLDOWN, 10_001, STALENESS,
        FEED,
        PUBLISHER, STOPPER, DAO, &clock, sc.ctx(),
    );
    abort
}

// === Monkey: two markets from one AdminCap get distinct policies + distinct oracles ===

#[test]
fun two_markets_are_isolated() {
    let mut sc = ts::begin(DEPLOYER);
    admin::init_for_testing(sc.ctx());

    sc.next_tx(DEPLOYER);
    let admin_cap = ts::take_from_sender<AdminCap>(&sc);
    let clock = clock::create_for_testing(sc.ctx());
    admin::register_market<BTC_MKT>(
        &admin_cap, LTV, WINDOW, COOLDOWN, MAX_CONF, STALENESS,
        FEED,
        PUBLISHER, STOPPER, DAO, &clock, sc.ctx(),
    );
    admin::register_market<ETH_MKT>(
        &admin_cap, LTV, WINDOW, COOLDOWN, MAX_CONF, STALENESS,
        FEED,
        PUBLISHER, STOPPER, DAO, &clock, sc.ctx(),
    );
    ts::return_to_sender(&sc, admin_cap);
    clock.destroy_for_testing();

    sc.next_tx(DEPLOYER);
    let btc = ts::take_shared<RiskPolicy<BTC_MKT>>(&sc);
    let eth = ts::take_shared<RiskPolicy<ETH_MKT>>(&sc);
    // Distinct policy objects, each bound to its own distinct oracle.
    assert!(object::id(&btc) != object::id(&eth));
    assert!(policy::bound_oracle_id(&btc) != policy::bound_oracle_id(&eth));
    ts::return_shared(btc);
    ts::return_shared(eth);
    sc.end();
}
