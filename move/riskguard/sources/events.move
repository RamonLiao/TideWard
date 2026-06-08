/// Single import surface for RiskGuard on-chain events.
///
/// Events ARE the audit trail (notes.md 架構基石 #4): no `ActionLog` object.
/// The indexer subscribes to these via gRPC and materializes to Postgres.
///
/// Structs are public (part of the ABI the indexer decodes) but their fields
/// are module-private, so cross-module emitters MUST go through the
/// `emit_*` functions below — that keeps event shape changes contained here.
module riskguard::events;

use std::type_name::TypeName;
use sui::event;

// === Event structs (spec §2.5) ===

public struct ScorePosted has copy, drop {
    market: TypeName,
    score_bps: u16,
    ts_ms: u64,
    nonce: u64,
}

public struct ActionExecuted has copy, drop {
    action_id: u64,
    market: TypeName,
    kind: u8,
    prev_ltv: u16,
    new_ltv: u16,
    score_bps: u16,
    ts_ms: u64,
}

public struct ActionReverted has copy, drop {
    action_id: u64,
    market: TypeName,
    by: address,
    ts_ms: u64,
}

/// Oracle kill-switch toggled. Keyed by oracle `ID`, not market: pausing is
/// oracle-scoped (spec §2.7 — `active=false` aborts every `post_score_and_apply`),
/// and `pause_oracle` has no market type parameter. `by` records the signer for
/// the audit trail (any `EmergencyStopCap` holder pauses; `AdminCap` resumes).
///
/// Deviation from spec §2.5 `PolicyPaused{market}` (Rule 7, confirmed 2026-05-30):
/// market-keying was wrong — the kill switch is per-oracle, and the pause entry
/// carries no `M`. Split into Paused/Resumed for an unambiguous on/off audit log.
public struct OraclePaused has copy, drop {
    oracle: ID,
    by: address,
    ts_ms: u64,
}

public struct OracleResumed has copy, drop {
    oracle: ID,
    by: address,
    ts_ms: u64,
}

/// A market came online via `admin::register_market`. The off-chain registry
/// (A1) subscribes to this to materialize the `M → policy_id/oracle_id` binding
/// that lenders use to look up (and anti-spoof) the right `RiskPolicy`.
public struct MarketRegistered has copy, drop {
    market: TypeName,
    policy_id: ID,
    oracle_id: ID,
    ts_ms: u64,
}

/// Upgrade proposed via `upgrade_registry::propose_upgrade`. `eta_ms` is the
/// earliest executable time (`proposed_at_ms + timelock_ms`) — what the dashboard
/// surfaces as the countdown. `epoch` disambiguates re-proposals of the same digest.
public struct UpgradeProposed has copy, drop {
    digest: vector<u8>,
    policy: u8,
    eta_ms: u64,
    epoch: u64,
}

/// A pending upgrade was cancelled by an AdminCap holder. `by` records the signer
/// for the audit trail; `epoch` matches the cancelled proposal.
public struct UpgradeCancelled has copy, drop {
    digest: vector<u8>,
    epoch: u64,
    by: address,
}

/// A pending upgrade passed its timelock and was authorized (ticket issued).
public struct UpgradeExecuted has copy, drop {
    digest: vector<u8>,
    epoch: u64,
}

/// A DAO protective override was applied via `override::force_protect`. Distinct
/// from `ActionExecuted` (oracle-driven): this is human-driven and monotonic-
/// protective. `reason_code` is carried here so the indexer audits the why
/// without reading the policy object.
public struct OverrideApplied has copy, drop {
    market: TypeName,
    action_id: u64,
    prev_ltv: u16,
    new_ltv: u16,
    prev_flags: u8,
    new_flags: u8,
    reason_code: u8,
    by: address,
    ts_ms: u64,
}

// === Emitters (package-internal) ===

public(package) fun emit_action_executed(
    market: TypeName,
    action_id: u64,
    kind: u8,
    prev_ltv: u16,
    new_ltv: u16,
    score_bps: u16,
    ts_ms: u64,
) {
    event::emit(ActionExecuted { action_id, market, kind, prev_ltv, new_ltv, score_bps, ts_ms });
}

public(package) fun emit_action_reverted(
    market: TypeName,
    action_id: u64,
    by: address,
    ts_ms: u64,
) {
    event::emit(ActionReverted { action_id, market, by, ts_ms });
}

/// Emitted by oracle.move when a score is posted (before the policy mutation).
public(package) fun emit_score_posted(market: TypeName, score_bps: u16, ts_ms: u64, nonce: u64) {
    event::emit(ScorePosted { market, score_bps, ts_ms, nonce });
}

/// Emitted by `oracle::pause_oracle` — kill switch engaged.
public(package) fun emit_oracle_paused(oracle: ID, by: address, ts_ms: u64) {
    event::emit(OraclePaused { oracle, by, ts_ms });
}

/// Emitted by `oracle::resume_oracle` — kill switch released.
public(package) fun emit_oracle_resumed(oracle: ID, by: address, ts_ms: u64) {
    event::emit(OracleResumed { oracle, by, ts_ms });
}

/// Emitted by `admin::register_market` once a market's policy + oracle are live.
public(package) fun emit_market_registered(market: TypeName, policy_id: ID, oracle_id: ID, ts_ms: u64) {
    event::emit(MarketRegistered { market, policy_id, oracle_id, ts_ms });
}

/// Emitted by `upgrade_registry::propose_upgrade`.
public(package) fun emit_upgrade_proposed(digest: vector<u8>, policy: u8, eta_ms: u64, epoch: u64) {
    event::emit(UpgradeProposed { digest, policy, eta_ms, epoch });
}

/// Emitted by `upgrade_registry::cancel_upgrade`.
public(package) fun emit_upgrade_cancelled(digest: vector<u8>, epoch: u64, by: address) {
    event::emit(UpgradeCancelled { digest, epoch, by });
}

/// Emitted by `upgrade_registry::execute_upgrade` once the timelock elapses.
public(package) fun emit_upgrade_executed(digest: vector<u8>, epoch: u64) {
    event::emit(UpgradeExecuted { digest, epoch });
}

/// Emitted by `policy::apply_override` (driven by `override::force_protect`).
public(package) fun emit_override_applied(
    market: TypeName,
    action_id: u64,
    prev_ltv: u16,
    new_ltv: u16,
    prev_flags: u8,
    new_flags: u8,
    reason_code: u8,
    by: address,
    ts_ms: u64,
) {
    event::emit(OverrideApplied {
        market, action_id, prev_ltv, new_ltv, prev_flags, new_flags, reason_code, by, ts_ms,
    });
}
