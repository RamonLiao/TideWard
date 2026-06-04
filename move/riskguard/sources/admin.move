/// RiskGuard genesis + market registration — the AdminCap-gated control plane.
///
/// Two responsibilities:
///   1. `init`: mint the single root `AdminCap` at publish and hand it to the
///      deployer (must be the ops multisig — a deployment-time invariant, see
///      threat model).
///   2. `register_market<M>`: the ONLY way a market comes online. It creates the
///      market's `RiskOracle` and `RiskPolicy<M>`, mints the three per-market
///      caps, shares both objects, and emits `MarketRegistered` for the off-chain
///      registry (A1: M → policy_id/oracle_id binding).
///
/// Design anchors (tasks/notes.md):
///   - No external object-id inputs: the oracle is created *inside* this function,
///     so every cap and the policy bind to the same fresh `oracle_id`. A caller
///     cannot point a cap at the wrong oracle (red-team vector #2).
///   - `object::id` is read before sharing; ids are stable across `share_object`,
///     which is what lets policy/caps bind an oracle that is shared on the next line.
///   - `RiskOracle` has `key` only (no `store`), so it cannot be shared from here —
///     `oracle::share_oracle` is the in-defining-module seam that does it.
module riskguard::admin;

use sui::clock::Clock;
use std::type_name;
use riskguard::caps::{Self, AdminCap};
use riskguard::oracle;
use riskguard::policy;
use riskguard::events;

/// Publish-time genesis: mint the root `AdminCap` and transfer it to the
/// deployer. The deployer MUST be the ops multisig (2-of-3 testnet) — this is a
/// deployment-time invariant, not enforceable on-chain.
fun init(ctx: &mut TxContext) {
    transfer::public_transfer(caps::new_admin_cap(ctx), ctx.sender());
}

/// Bring a new market online. AdminCap-gated (possession = authorization).
///
/// Order (fresh objects → no external ids → no misbinding):
///   1. create oracle, read its id
///   2. create policy<M> bound to that oracle, read its id
///   3. mint + transfer the three caps to their operational holders
///   4. emit MarketRegistered (off-chain registry)
///   5. share policy (has store) here; share oracle via its own module seam
///
/// Cap recipients (threat-model separation):
///   - `publisher_recipient`: KMS-managed publisher address (RiskOraclePublisherCap)
///   - `stop_recipient`:      on-call ops hot wallet        (EmergencyStopCap)
///   - `override_recipient`:  per-market DAO multisig        (OverrideCap<M>)
///
/// KNOWN LIMITATION (codex review F2, 2026-05-30): there is no on-chain guard
/// against registering the same `M` twice — each call mints a fresh, internally-
/// consistent policy/oracle pair and emits another `MarketRegistered`. This is
/// deliberate (arch A1/A2): the off-chain registry is the source of truth and
/// applies "latest MarketRegistered wins" per `M`; we do NOT reintroduce a central
/// shared registry object (A2 removed exactly that to avoid consensus contention).
/// Double-registration requires `AdminCap`, so it is an ops error, not an attack.
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
    let oracle_id = object::id(&oracle);

    let policy = policy::new<M>(
        ltv_default_bps,
        revert_window_ms,
        min_loosen_interval_ms,
        max_conf_bps,
        oracle_id,
        ctx,
    );
    let policy_id = object::id(&policy);

    transfer::public_transfer(caps::new_publisher_cap(oracle_id, ctx), publisher_recipient);
    transfer::public_transfer(caps::new_stop_cap(oracle_id, ctx), stop_recipient);
    transfer::public_transfer(caps::new_override_cap<M>(policy_id, ctx), override_recipient);

    events::emit_market_registered(
        type_name::with_defining_ids<M>(),
        policy_id,
        oracle_id,
        clock.timestamp_ms(),
    );

    transfer::public_share_object(policy);
    oracle::share_oracle(oracle);
}

// === Test-only ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
