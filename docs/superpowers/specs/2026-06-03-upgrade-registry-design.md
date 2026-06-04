# upgrade_registry.move — Design (C4 Upgradeability)

> Date: 2026-06-03 · Status: approved (brainstorming) · Spec ref: architecture-spec §2.8 (C4), §5.1 (P0-1)

## Goal

Wrap the package `UpgradeCap` in a shared `UpgradeRegistry` so package upgrades go
through a 72h timelock with full event transparency. Raw cap never exposed.
Emergencies use `pause_oracle` (B2), not a fast-path upgrade.

Scope: **one new module** `upgrade_registry.move` + append events to `events.move`.
No changes to policy/oracle/admin/pyth_adapter/caps.

## Object model

```move
public struct UpgradeRegistry has key {
    id: UID,
    cap: UpgradeCap,                 // wrapped; never returned/exposed
    timelock_ms: u64,                // hardcoded 259_200_000 (72h), no setter in MVP
    pending: Option<PendingUpgrade>, // None = no proposal in flight
}

public struct PendingUpgrade has store, drop {
    digest: vector<u8>,   // 32-byte bytecode digest (validated only at execute)
    policy: u8,           // sui::package upgrade policy (compatible/additive/dep-only)
    proposed_at_ms: u64,
    epoch: u64,           // monotonic; bumped on cancel to disambiguate re-proposals
}
```

`Option<PendingUpgrade>` (not bool + bare fields) so "has/no proposal" is type-enforced —
callers cannot read a stale digest.

## API

| fn | auth | effect |
|---|---|---|
| `init_upgrade_registry(&AdminCap, UpgradeCap, ctx)` | AdminCap | wrap cap → `share_object(registry)`. Post-publish 2nd tx (deployer holds AdminCap+UpgradeCap). One-shot: cap is moved in, cannot be called again. `epoch` starts 0. |
| `propose_upgrade(&AdminCap, &mut UpgradeRegistry, digest: vector<u8>, policy: u8, &Clock)` | AdminCap (2-of-3) | abort `EUpgradePending` if pending is some; abort `EPolicyTooPermissive` if `policy < package::upgrade_policy(&cap)` (fail-fast, see F2); else set `pending = some(PendingUpgrade{ digest, policy, now, epoch })`. Emit `UpgradeProposed`. |
| `cancel_upgrade(&AdminCap, &mut UpgradeRegistry)` | AdminCap | abort `ENoPending` if none; else extract+drop pending, **bump stored epoch counter**, emit `UpgradeCancelled`. |
| `execute_upgrade(&mut UpgradeRegistry, &Clock): UpgradeTicket` | **permissionless** | abort `ENoPending` if none; assert `now >= proposed_at_ms` then `now - proposed_at_ms >= timelock_ms` (`ETimelockActive`); `package::authorize_upgrade(&mut cap, policy, digest)` → return ticket. **Does NOT clear pending** (cleared at commit). Emit `UpgradeExecuted`. |
| `commit_upgrade(&mut UpgradeRegistry, UpgradeReceipt)` | permissionless | `package::commit_upgrade(&mut cap, receipt)` (bumps cap version) + clear pending. |

`execute` + `commit` are permissionless: after `execute`, the PTB must receive the new
bytecode and `commit` in the **same transaction**; anyone can advance a timelock-elapsed
proposal, preventing RiskGuard from squatting on a pending upgrade (spec §2.8).

### epoch semantics

`epoch` is a single monotonic counter stored on the registry (carried into each
`PendingUpgrade` at propose time). Bumped on `cancel`. So a cancel→re-propose of the same
digest emits events with distinct `epoch` values — the indexer/dashboard never conflates
the old proposal's cancel with the new proposal. `execute`/`commit` do not bump it.

## Error codes

```
EUpgradePending     = 40   // propose while a proposal is already in flight
ENoPending          = 41   // cancel/execute with no pending proposal
ETimelockActive     = 42   // execute before 72h elapsed
EPolicyTooPermissive = 43  // proposed policy < cap's current policy (fail-fast vs framework ETooPermissive at execute)
```

(Follows the project's plain-`u64 const` error convention; see oracle.move 30/31 range.)

## Events (append to events.move)

```move
public struct UpgradeProposed  has copy, drop { digest: vector<u8>, policy: u8, eta_ms: u64, epoch: u64 }
public struct UpgradeCancelled has copy, drop { digest: vector<u8>, epoch: u64, by: address }
public struct UpgradeExecuted  has copy, drop { digest: vector<u8>, epoch: u64 }
```

`eta_ms = proposed_at_ms + timelock_ms` (the earliest executable time — what a dashboard
shows). Emitted via new `public(package) emit_upgrade_*` fns, matching existing convention.

## Threat model (core access control — red team applies)

Attack vectors and defenses:

1. **Execute before timelock** → `assert now - proposed_at_ms >= timelock_ms` (`ETimelockActive`).
2. **Re-propose to overwrite a proposal under review** → pending-is-some aborts (`EUpgradePending`); must `cancel` first, which leaves an on-chain event.
3. **Propose/cancel without AdminCap** → `&AdminCap` by-ref parameter gates both.
4. **Execute on empty registry / no pending** → `option::is_some` check (`ENoPending`).
5. **u64 time underflow/overflow** → assert `now >= proposed_at_ms` before the subtraction; subtraction form (not `proposed_at + timelock` which could overflow near u64::MAX).

Accepted residual risks (documented):
- **digest not verifiable at propose time** — Move cannot see future bytecode; `authorize_upgrade`
  only checks digest at execute. A wrong/malicious digest requires 2-of-3 AdminCap collusion
  and is exposed for 72h via `UpgradeProposed` event for external audit. Accepted (spec §2.8).
- **No on-chain cancel-rate limit** — velocity abuse mitigated by event transparency + SaaS SLA
  (cancel rate > 30%/mo = breach), per spec §2.8, not an on-chain limit.
- **Custody**: testnet/MVP keeps AdminCap 2-of-3; mainnet pre-launch swaps UpgradeCap custody to
  3-of-5 with 2 external trustees (P0-1). Out of contract scope (key management), documented only.

## Testing strategy

**Gap closed (verified against framework source 2026-06-03):** `sui::package` exposes
`#[test_only] test_publish(id, ctx): UpgradeCap` and `#[test_only] test_upgrade(ticket): UpgradeReceipt`.
This means the **full lifecycle is unit-testable** — no e2e-only gap (unlike pyth `read_price`):
mint a cap with `test_publish`, `propose → execute_upgrade` (real `UpgradeTicket`), convert it via
`package::test_upgrade`, then `commit_upgrade` and assert `package::version(&cap) == 2`.

**On-chain unit tests** (`test_scenario` + `clock::create_for_testing` + `package::test_publish`):
- init_upgrade_registry → registry shared, cap wrapped, version 1
- propose happy path → pending set, event shape
- repeat propose while pending → `EUpgradePending`
- propose with policy < cap.policy (raise cap via `package::only_additive_upgrades`) → `EPolicyTooPermissive`
- cancel → pending cleared, epoch bumped
- cancel then re-propose same digest → succeeds, new epoch
- execute before timelock → `ETimelockActive`
- execute at timelock boundary → returns `UpgradeTicket` (consume via `package::test_upgrade`), pending still present
- **full lifecycle**: propose → advance clock → execute → `test_upgrade` → commit → assert version bumped + pending cleared
- cancel/execute with no pending → `ENoPending`
- propose/cancel without AdminCap → cap-gated (compile-time / not constructable)

Note: `test_publish` always mints policy `COMPATIBLE`(0); raise it with `package::only_additive_upgrades`
to exercise `EPolicyTooPermissive`. Constants (framework source): `COMPATIBLE=0`, `ADDITIVE=128`, `DEP_ONLY=192`.

**Still e2e-validated (not blocking):** a real on-chain upgrade against testnet confirms the
PTB shape `execute_upgrade → Upgrade command → commit_upgrade` works against the live runtime
(the `Upgrade` command is what `test_upgrade` simulates). Optional post-merge.

## Upgrade lifecycle (verified against sui-framework source, 2026-06-03)

`authorize_upgrade` zeroes `cap.package` and asserts it is non-zero (`EAlreadyAuthorized`);
`commit_upgrade` restores `cap.package` and bumps `cap.version`. `UpgradeTicket` and
`UpgradeReceipt` are **hot potatoes (no `drop`)** — the ticket must be consumed by the PTB's
`Upgrade` command, producing a receipt that must be consumed by `commit_upgrade`, all in the
**same transaction**. Consequence: there is no committed on-chain state where `execute` ran but
`commit` did not — the PTB either completes all three (execute → Upgrade → commit) or reverts
atomically (cap.package un-zeroes). This is why `execute_upgrade` does not clear `pending`
(commit does) and why a reverted upgrade attempt is freely retryable. The real upgrade is one
PTB: `execute_upgrade → Upgrade command → commit_upgrade`.

This also confirms the unit-test gap: the test env cannot construct hot-potato
`UpgradeTicket`/`UpgradeReceipt`, so execute+commit are e2e-only.

`policy` constants (framework): `COMPATIBLE = 0`, `ADDITIVE = 128`, dep-only (highest). The
restrictiveness check is `policy >= cap.policy` (framework `ETooPermissive` at execute); F2 adds
the same check at propose for fail-fast. (`package::upgrade_policy(&cap): u8` accessor — confirm
exact name against framework source at implementation.)

## Locked decisions

- (a) `init_upgrade_registry` is AdminCap-gated (holding UpgradeCap is already authority; the
  extra cap check guards against mis-wrapping).
- (b) `timelock_ms` hardcoded 259_200_000, no setter. v1 adds a meta-timelock to change it.
- (c) Scope = upgrade_registry.move + events.move append only. No other module touched.
