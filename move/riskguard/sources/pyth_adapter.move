/// Pyth → RiskGuard trust-boundary translator. Decodes a verified Pyth `PriceInfoObject`
/// into an `oracle::PriceReading` (the only production mint path). `read_price` is the thin
/// PriceInfoObject-decoding wrapper (off-chain PTB integration-tested); `compute_reading` is the
/// pure, unit-tested core. See docs/superpowers/specs/2026-05-30-pyth-adapter-design.md.
module riskguard::pyth_adapter;

use riskguard::oracle::{Self, RiskOracle, PriceReading};
use sui::clock::Clock;
use pyth::pyth;
use pyth::price_info;
use pyth::price_identifier;
use pyth::price;
use pyth::i64;

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

/// Decode a verified Pyth reading into a `PriceReading`. The off-chain executor calls this in the
/// same PTB, AFTER `SuiPythClient.updatePriceFeeds` has refreshed `price_info_object`, and BEFORE
/// `oracle::post_score_and_apply`. Uses Pyth's canonical `get_price_no_older_than` (never
/// `get_price_unsafe`) with the per-oracle staleness window; the feed-id bind reads directly from
/// `oracle` so the checked feed and the written oracle are the same object (no caller discretion).
public fun read_price(
    oracle: &RiskOracle,
    price_info_object: &price_info::PriceInfoObject,
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

#[test_only] use riskguard::oracle::{reading_conf_bps, reading_publish_ts_ms};

#[test]
fun happy_path_conf_bps_and_ts() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    // price = 1_000_000 (BUCK ~1.0 at expo -6), conf = 2_000 → 2000*10000/1000000 = 20 bps
    let r = compute_reading(feed, feed, 1_000_000, false, 2_000, 1_700);
    assert!(reading_conf_bps(&r) == 20, 0);
    assert!(reading_publish_ts_ms(&r) == 1_700_000, 1);
}

#[test, expected_failure(abort_code = EWrongFeed)]
fun wrong_feed_aborts() {
    let exp = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let act = x"00000000000000000000000000000000000000000000000000000000000000bb";
    let _r = compute_reading(exp, act, 1_000_000, false, 2_000, 1_700);
    abort 99
}

#[test, expected_failure(abort_code = EInvalidPrice)]
fun negative_price_aborts() {
    let feed = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let _r = compute_reading(feed, feed, 1_000_000, true, 2_000, 1_700);
    abort 99
}

#[test, expected_failure(abort_code = EInvalidPrice)]
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

// === Monkey tests (per .claude/rules/test.md) — extreme conf/price ratios ===

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

// === Red team: a truncated/malformed feed id can't slip past the byte compare ===
// Attacker supplies a shorter feed whose bytes prefix-match the expected one →
// vector!=vector is a length-aware compare, so it still aborts EWrongFeed.
#[test, expected_failure(abort_code = EWrongFeed)]
fun redteam_truncated_feed_aborts() {
    let exp = x"00000000000000000000000000000000000000000000000000000000000000aa";
    let act = x"000000000000000000000000000000000000000000000000000000000000"; // 30 bytes, prefix-matches
    let _r = compute_reading(exp, act, 1_000_000, false, 2_000, 1_700);
    abort 99
}
