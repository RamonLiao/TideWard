/// RiskGuard package upgradeability — the slowest, widest-attested authority (spec C4 §2.8).
///
/// Wraps the package `UpgradeCap` in a shared `UpgradeRegistry` so the raw cap is
/// never exposed. Every upgrade goes through a 72h timelock: `propose_upgrade`
/// (AdminCap-gated) starts the timer; after it elapses anyone may `execute_upgrade`
/// (permissionless, so RiskGuard cannot squat on a pending upgrade) which returns a
/// `package::UpgradeTicket`; the PTB then runs the on-chain `Upgrade` command and
/// `commit_upgrade` consumes the resulting `UpgradeReceipt`, bumping the cap version.
/// Emergencies do NOT get a fast path — use `oracle::pause_oracle` (B2) instead.
///
/// Lifecycle is atomic per spec: `UpgradeTicket`/`UpgradeReceipt` are hot potatoes,
/// so `execute → Upgrade → commit` is one transaction; there is no committed state
/// where execute ran but commit did not. `execute_upgrade` therefore leaves `pending`
/// in place (a reverted attempt is freely retryable) and `commit_upgrade` clears it.
///
/// DAG note (Rule 8): depends only on `caps` (AdminCap) and `events`. No module
/// depends on this one. `timelock_ms` is hardcoded (MVP); v1 adds a meta-timelock.
module riskguard::upgrade_registry;

use sui::clock::Clock;
use sui::package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt};
use riskguard::caps::AdminCap;
use riskguard::events;

// === Errors (module-local plain u64, off-chain treats as contract; spec §2.6) ===
const EUpgradePending: u64      = 40; // propose while a proposal is already in flight
const ENoPending: u64           = 41; // cancel/execute with no pending proposal
const ETimelockActive: u64      = 42; // execute before the 72h timelock elapsed
const EPolicyTooPermissive: u64 = 43; // proposed policy < cap's current policy (fail-fast)

// 72h in milliseconds. MVP: hardcoded, no setter (v1: meta-timelock).
const TIMELOCK_MS: u64 = 259_200_000;

/// Shared object wrapping the package `UpgradeCap`. `key` only (no `store`) so it
/// cannot be wrapped/transferred out — the cap is locked to consensus access here.
public struct UpgradeRegistry has key {
    id: UID,
    cap: UpgradeCap,
    timelock_ms: u64,
    pending: Option<PendingUpgrade>,
    epoch: u64, // monotonic; carried into each PendingUpgrade, bumped on cancel
}

/// An in-flight upgrade proposal. `digest` is validated only at execute time by
/// `package::authorize_upgrade` (Move cannot see future bytecode at propose time).
public struct PendingUpgrade has store, drop {
    digest: vector<u8>,
    policy: u8,
    proposed_at_ms: u64,
    epoch: u64,
}

/// Post-publish bootstrap: wrap the freshly minted `UpgradeCap` and share the
/// registry. AdminCap-gated (holding the cap is already authority; this guards
/// against mis-wrapping). One-shot: `cap` is moved in, so this cannot run twice.
public fun init_upgrade_registry(cap: UpgradeCap, _: &AdminCap, ctx: &mut TxContext) {
    let registry = UpgradeRegistry {
        id: object::new(ctx),
        cap,
        timelock_ms: TIMELOCK_MS,
        pending: option::none(),
        epoch: 0,
    };
    transfer::share_object(registry);
}

// === Read helpers ===

/// True when a proposal is in flight.
public fun has_pending(reg: &UpgradeRegistry): bool {
    reg.pending.is_some()
}

/// The configured timelock in milliseconds.
public fun timelock_ms(reg: &UpgradeRegistry): u64 {
    reg.timelock_ms
}

// === Propose ===

/// Propose an upgrade. AdminCap-gated (2-of-3 ops). Starts the 72h timer.
/// Aborts if a proposal is already in flight (`EUpgradePending`) — cancel it
/// first, which leaves an on-chain `UpgradeCancelled` event. Fail-fast on a
/// policy more permissive than the cap allows (`EPolicyTooPermissive`), rather
/// than letting `package::authorize_upgrade` abort 72h later at execute.
public fun propose_upgrade(
    reg: &mut UpgradeRegistry,
    _: &AdminCap,
    digest: vector<u8>,
    policy: u8,
    clock: &Clock,
) {
    assert!(reg.pending.is_none(), EUpgradePending);
    assert!(policy >= package::upgrade_policy(&reg.cap), EPolicyTooPermissive);

    let now = clock.timestamp_ms();
    let epoch = reg.epoch;
    reg.pending = option::some(PendingUpgrade {
        digest,
        policy,
        proposed_at_ms: now,
        epoch,
    });
    events::emit_upgrade_proposed(digest, policy, now + reg.timelock_ms, epoch);
}

/// The current epoch counter (read by tests/indexer reconciliation).
public fun current_epoch(reg: &UpgradeRegistry): u64 {
    reg.epoch
}

/// Cancel the in-flight proposal. AdminCap-gated. Bumps the epoch so a later
/// re-proposal of the same digest is unambiguous in the event log. Aborts if
/// nothing is pending (`ENoPending`).
public fun cancel_upgrade(reg: &mut UpgradeRegistry, _: &AdminCap, ctx: &TxContext) {
    assert!(reg.pending.is_some(), ENoPending);
    let PendingUpgrade { digest, epoch, .. } = reg.pending.extract();
    reg.epoch = reg.epoch + 1;
    events::emit_upgrade_cancelled(digest, epoch, ctx.sender());
}

// === Execute ===

/// Permissionless once the timelock elapses (prevents RiskGuard squatting on a
/// pending upgrade). Authorizes the upgrade and returns the `UpgradeTicket` for
/// the PTB's `Upgrade` command. Does NOT clear `pending` — `commit_upgrade` does,
/// after the receipt comes back. A reverted attempt is therefore retryable.
public fun execute_upgrade(reg: &mut UpgradeRegistry, clock: &Clock): UpgradeTicket {
    assert!(reg.pending.is_some(), ENoPending);
    let pending = reg.pending.borrow();
    let now = clock.timestamp_ms();
    // Subtraction form (assert now >= proposed first) avoids u64 overflow near max.
    assert!(now >= pending.proposed_at_ms, ETimelockActive);
    assert!(now - pending.proposed_at_ms >= reg.timelock_ms, ETimelockActive);

    let digest = pending.digest;
    let policy = pending.policy;
    let epoch = pending.epoch;
    events::emit_upgrade_executed(digest, epoch);
    package::authorize_upgrade(&mut reg.cap, policy, digest)
}

/// The wrapped cap's current version (read by tests/dashboard).
public fun cap_version(reg: &UpgradeRegistry): u64 {
    package::version(&reg.cap)
}

/// Finalize the upgrade: consume the `UpgradeReceipt` (bumps the cap version) and
/// clear `pending`. Permissionless — must run in the same PTB as `execute_upgrade`
/// and the `Upgrade` command (the receipt is a hot potato).
public fun commit_upgrade(reg: &mut UpgradeRegistry, receipt: UpgradeReceipt) {
    package::commit_upgrade(&mut reg.cap, receipt);
    let PendingUpgrade { .. } = reg.pending.extract();
}
