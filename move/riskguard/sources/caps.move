/// RiskGuard capability objects (spec §2.7).
///
/// Defines `OverrideCap<M>` (revert authority, used by `policy.move`) plus the
/// three oracle-path caps used by `oracle.move`: `AdminCap` (global ops),
/// `RiskOraclePublisherCap` (gates `post_score_and_apply`), and
/// `EmergencyStopCap` (one-shot kill switch). `admin.move` is still TODO and
/// will own the AdminCap-gated public entries that mint these.
///
/// Constructors are `public(package)` so only RiskGuard modules mint caps —
/// minting is gated by `AdminCap` possession in `admin.move`. Exposing them as
/// `public` would let anyone mint a cap and bypass authorization.
module riskguard::caps;

/// Authorizes reverting actions on exactly one `RiskPolicy<M>`.
/// `phantom M` scopes by market type; `policy_id` pins the exact instance
/// (anti-spoof, A1). Held by the per-market DAO multisig address.
public struct OverrideCap<phantom M> has key, store {
    id: UID,
    policy_id: ID,
}

/// Global RiskGuard operations cap (spec §2.7). Held by the ops multisig
/// (2-of-3 testnet, see threat model). Gates market registration, cap minting,
/// and `oracle::resume_oracle`. Not market-scoped — one root ops authority.
public struct AdminCap has key, store {
    id: UID,
}

/// Gates `oracle::post_score_and_apply`. Held by the KMS-managed publisher
/// address. `oracle_id` pins it to exactly one `RiskOracle` so a leaked
/// publisher key can only post to its own oracle (B2 blast-radius cap).
public struct RiskOraclePublisherCap has key, store {
    id: UID,
    oracle_id: ID,
}

/// One-shot kill switch (spec §2.7, B2 asymmetric stop/start). Held by on-call
/// ops hot wallets; any single holder can `pause_oracle`. Resume requires the
/// slower `AdminCap`. `oracle_id` pins it to one `RiskOracle`.
public struct EmergencyStopCap has key, store {
    id: UID,
    oracle_id: ID,
}

/// The policy this cap is allowed to revert. Read by `policy::revert_action`.
public fun override_policy_id<M>(cap: &OverrideCap<M>): ID {
    cap.policy_id
}

/// The oracle this publisher cap may post to. Read by `oracle::post_score_and_apply`.
public fun publisher_oracle_id(cap: &RiskOraclePublisherCap): ID {
    cap.oracle_id
}

/// The oracle this stop cap may pause. Read by `oracle::pause_oracle`.
public fun stop_oracle_id(cap: &EmergencyStopCap): ID {
    cap.oracle_id
}

/// Mint an `OverrideCap<M>` bound to `policy_id`. Called by `admin.move` at
/// market registration (AdminCap-gated there).
public(package) fun new_override_cap<M>(policy_id: ID, ctx: &mut TxContext): OverrideCap<M> {
    OverrideCap { id: object::new(ctx), policy_id }
}

/// Mint the root `AdminCap`. Called once at package init / genesis in `admin.move`.
public(package) fun new_admin_cap(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

/// Mint a `RiskOraclePublisherCap` bound to `oracle_id`. AdminCap-gated in `admin.move`.
public(package) fun new_publisher_cap(oracle_id: ID, ctx: &mut TxContext): RiskOraclePublisherCap {
    RiskOraclePublisherCap { id: object::new(ctx), oracle_id }
}

/// Mint an `EmergencyStopCap` bound to `oracle_id`. AdminCap-gated in `admin.move`.
public(package) fun new_stop_cap(oracle_id: ID, ctx: &mut TxContext): EmergencyStopCap {
    EmergencyStopCap { id: object::new(ctx), oracle_id }
}
