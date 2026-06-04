# upgrade_registry.move Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the package `UpgradeCap` in a shared `UpgradeRegistry` enforcing a 72h timelock with permissionless execute/commit and full event transparency (spec C4 §2.8).

**Architecture:** One new module `riskguard::upgrade_registry` holding `UpgradeCap` + `Option<PendingUpgrade>` + monotonic `epoch`. Lifecycle = `init_upgrade_registry` (post-publish bootstrap, AdminCap-gated) → `propose_upgrade` (AdminCap, 72h timer starts) → `execute_upgrade` (permissionless, after timelock, returns `UpgradeTicket`) → `commit_upgrade` (permissionless, consumes `UpgradeReceipt`, bumps cap version). `cancel_upgrade` (AdminCap) clears pending and bumps epoch. Events appended to existing `events.move`.

**Tech Stack:** Sui Move 2024.beta, `sui::package` (authorize/commit_upgrade), `sui::clock`, `sui::test_scenario` + `sui::package::test_publish`/`test_upgrade` for tests.

**Spec:** `docs/superpowers/specs/2026-06-03-upgrade-registry-design.md`

**Conventions (match existing modules):**
- Error consts: `const EFoo: u64 = N;` with inline comment (see oracle.move).
- Heavy module doc-comment header (see oracle.move/caps.move).
- Cross-module events go through `public(package) emit_*` in events.move.
- Tests: `#[test_only] module riskguard::upgrade_registry_tests;`, `std::unit_test::assert_eq`, `#[expected_failure(abort_code = X, location = riskguard::upgrade_registry)]`.
- Build: `sui move build`; test: `sui move test` (run from `move/riskguard/`).

**Framework API (verified against source 2026-06-03):**
- `package::authorize_upgrade(cap: &mut UpgradeCap, policy: u8, digest: vector<u8>): UpgradeTicket`
- `package::commit_upgrade(cap: &mut UpgradeCap, receipt: UpgradeReceipt)`
- `package::upgrade_policy(cap: &UpgradeCap): u8`
- `package::version(cap: &UpgradeCap): u64` (for test assertions)
- Policy constants: `COMPATIBLE=0`, `ADDITIVE=128`, `DEP_ONLY=192`; accessors `additive_policy()` etc.
- `#[test_only] package::test_publish(id: ID, ctx): UpgradeCap` (policy=COMPATIBLE, version=1)
- `#[test_only] package::test_upgrade(ticket: UpgradeTicket): UpgradeReceipt`
- `package::only_additive_upgrades(cap: &mut UpgradeCap)` raises policy to ADDITIVE (for EPolicyTooPermissive test)

---

### Task 1: Append upgrade events to events.move

**Files:**
- Modify: `move/riskguard/sources/events.move`

- [ ] **Step 1: Add the three event structs** after the `MarketRegistered` struct (before the `// === Emitters ===` section)

```move
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
```

- [ ] **Step 2: Add the three emitters** at the end of the `// === Emitters ===` section

```move
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
```

- [ ] **Step 3: Build to verify it compiles**

Run: `sui move build`
Expected: builds with no new warnings (upstream Pyth doc-comment warnings are pre-existing). Unused-struct warnings for the new events are acceptable until Task 2 wires them.

- [ ] **Step 4: Commit**

```bash
git add move/riskguard/sources/events.move
git commit -m "feat(events): add Upgrade{Proposed,Cancelled,Executed} events"
```

---

### Task 2: Module skeleton — structs, errors, init_upgrade_registry

**Files:**
- Create: `move/riskguard/sources/upgrade_registry.move`
- Create: `move/riskguard/tests/upgrade_registry_tests.move`

- [ ] **Step 1: Write the failing test** (create the test file)

```move
#[test_only]
module riskguard::upgrade_registry_tests;

use sui::test_scenario as ts;
use sui::clock;
use sui::package::{Self, UpgradeCap};
use std::unit_test::assert_eq;
use riskguard::caps::{Self, AdminCap};
use riskguard::upgrade_registry::{Self, UpgradeRegistry};

const DEPLOYER: address = @0xAD;   // ops multisig (holds AdminCap + UpgradeCap)
const RANDO: address    = @0xBEEF; // permissionless executor
const TIMELOCK_MS: u64  = 259_200_000; // 72h
// Dummy 32-byte bytecode digest.
const DIGEST: vector<u8> = x"1111111111111111111111111111111111111111111111111111111111111111";

// Mints an AdminCap and a test UpgradeCap to DEPLOYER, returns nothing (objects in inventory).
fun mint_caps(sc: &mut ts::Scenario) {
    let admin = caps::new_admin_cap(sc.ctx());
    transfer::public_transfer(admin, DEPLOYER);
    let pkg_id = object::id_from_address(@0xCAFE);
    let ucap = package::test_publish(pkg_id, sc.ctx());
    transfer::public_transfer(ucap, DEPLOYER);
}

#[test]
fun init_wraps_cap_and_shares_registry() {
    let mut sc = ts::begin(DEPLOYER);
    mint_caps(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let ucap = ts::take_from_sender<UpgradeCap>(&sc);
    upgrade_registry::init_upgrade_registry(&admin, ucap, sc.ctx());
    ts::return_to_sender(&sc, admin);

    sc.next_tx(DEPLOYER);
    // Registry is now a shared object with no pending proposal.
    let reg = ts::take_shared<UpgradeRegistry>(&sc);
    assert!(!upgrade_registry::has_pending(&reg));
    assert_eq!(upgrade_registry::timelock_ms(&reg), TIMELOCK_MS);
    ts::return_shared(reg);
    sc.end();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sui move test init_wraps_cap_and_shares_registry`
Expected: FAIL — `riskguard::upgrade_registry` module / functions not found.

- [ ] **Step 3: Write the module** (create `upgrade_registry.move`)

```move
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
public fun init_upgrade_registry(_: &AdminCap, cap: UpgradeCap, ctx: &mut TxContext) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sui move test init_wraps_cap_and_shares_registry`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/upgrade_registry.move move/riskguard/tests/upgrade_registry_tests.move
git commit -m "feat(upgrade): UpgradeRegistry skeleton + init_upgrade_registry"
```

---

### Task 3: propose_upgrade (+ EUpgradePending, EPolicyTooPermissive)

**Files:**
- Modify: `move/riskguard/sources/upgrade_registry.move`
- Modify: `move/riskguard/tests/upgrade_registry_tests.move`

- [ ] **Step 1: Write the failing tests** (append to test module)

```move
// --- helper: init registry and return it shared-taken in a fresh tx ---
fun setup_registry(sc: &mut ts::Scenario) {
    mint_caps(sc);
    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let ucap = ts::take_from_sender<UpgradeCap>(sc);
    upgrade_registry::init_upgrade_registry(&admin, ucap, sc.ctx());
    ts::return_to_sender(sc, admin);
}

#[test]
fun propose_sets_pending() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::EUpgradePending)]
fun propose_twice_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    // Second proposal while one is pending must abort.
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::EPolicyTooPermissive)]
fun propose_too_permissive_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    mint_caps(&mut sc);
    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut ucap = ts::take_from_sender<UpgradeCap>(&sc);
    // Raise cap policy to ADDITIVE(128); proposing COMPATIBLE(0) is more permissive → abort.
    package::only_additive_upgrades(&mut ucap);
    upgrade_registry::init_upgrade_registry(&admin, ucap, sc.ctx());
    ts::return_to_sender(&sc, admin);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sui move test propose_`
Expected: FAIL — `propose_upgrade` not found.

- [ ] **Step 3: Implement propose_upgrade** (append to module, after read helpers)

```move
/// Propose an upgrade. AdminCap-gated (2-of-3 ops). Starts the 72h timer.
/// Aborts if a proposal is already in flight (`EUpgradePending`) — cancel it
/// first, which leaves an on-chain `UpgradeCancelled` event. Fail-fast on a
/// policy more permissive than the cap allows (`EPolicyTooPermissive`), rather
/// than letting `package::authorize_upgrade` abort 72h later at execute.
public fun propose_upgrade(
    _: &AdminCap,
    reg: &mut UpgradeRegistry,
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sui move test propose_`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/upgrade_registry.move move/riskguard/tests/upgrade_registry_tests.move
git commit -m "feat(upgrade): propose_upgrade with pending + policy fail-fast guards"
```

---

### Task 4: cancel_upgrade (epoch bump, re-propose, ENoPending)

**Files:**
- Modify: `move/riskguard/sources/upgrade_registry.move`
- Modify: `move/riskguard/tests/upgrade_registry_tests.move`

- [ ] **Step 1: Write the failing tests** (append to test module)

```move
#[test]
fun cancel_clears_pending_and_allows_reproposal() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());

    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));
    let epoch_before = upgrade_registry::current_epoch(&reg);

    upgrade_registry::cancel_upgrade(&admin, &mut reg);
    assert!(!upgrade_registry::has_pending(&reg));
    // Epoch advanced so the indexer can't conflate this cancel with a re-proposal.
    assert_eq!(upgrade_registry::current_epoch(&reg), epoch_before + 1);

    // Re-proposing the same digest now succeeds.
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::ENoPending)]
fun cancel_without_pending_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    upgrade_registry::cancel_upgrade(&admin, &mut reg); // no pending → abort

    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sui move test cancel_`
Expected: FAIL — `cancel_upgrade` / `current_epoch` not found.

- [ ] **Step 3: Implement cancel_upgrade + current_epoch helper** (append to module)

```move
/// The current epoch counter (read by tests/indexer reconciliation).
public fun current_epoch(reg: &UpgradeRegistry): u64 {
    reg.epoch
}

/// Cancel the in-flight proposal. AdminCap-gated. Bumps the epoch so a later
/// re-proposal of the same digest is unambiguous in the event log. Aborts if
/// nothing is pending (`ENoPending`).
public fun cancel_upgrade(_: &AdminCap, reg: &mut UpgradeRegistry, ctx: &TxContext) {
    assert!(reg.pending.is_some(), ENoPending);
    let PendingUpgrade { digest, policy: _, proposed_at_ms: _, epoch } = reg.pending.extract();
    reg.epoch = reg.epoch + 1;
    events::emit_upgrade_cancelled(digest, epoch, ctx.sender());
}
```

> Note: `cancel_upgrade` takes `&TxContext` to record `sender()` in the event. Update the
> test calls in Step 1 to pass `sc.ctx()` — i.e. `cancel_upgrade(&admin, &mut reg, sc.ctx())`.
> (Adjust both `cancel_` tests accordingly before running Step 4.)

- [ ] **Step 4: Fix test calls then run to verify they pass**

Edit the two `cancel_upgrade(&admin, &mut reg)` calls in the test file to `cancel_upgrade(&admin, &mut reg, sc.ctx())`.

Run: `sui move test cancel_`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/upgrade_registry.move move/riskguard/tests/upgrade_registry_tests.move
git commit -m "feat(upgrade): cancel_upgrade with epoch bump + ENoPending guard"
```

---

### Task 5: execute_upgrade (timelock gate + authorize)

**Files:**
- Modify: `move/riskguard/sources/upgrade_registry.move`
- Modify: `move/riskguard/tests/upgrade_registry_tests.move`

- [ ] **Step 1: Write the failing tests** (append to test module)

```move
#[test]
#[expected_failure(abort_code = upgrade_registry::ETimelockActive)]
fun execute_before_timelock_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    ts::return_to_sender(&sc, admin);

    // Permissionless executor, but only 1s elapsed → abort.
    sc.next_tx(RANDO);
    clk.set_for_testing(2_000);
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    // Unreachable; consume to satisfy the type checker.
    let _ = package::test_upgrade(ticket);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::ENoPending)]
fun execute_without_pending_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(RANDO);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    let _ = package::test_upgrade(ticket);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sui move test execute_`
Expected: FAIL — `execute_upgrade` not found.

- [ ] **Step 3: Implement execute_upgrade** (append to module)

```move
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sui move test execute_`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/upgrade_registry.move move/riskguard/tests/upgrade_registry_tests.move
git commit -m "feat(upgrade): execute_upgrade with timelock gate, returns UpgradeTicket"
```

---

### Task 6: commit_upgrade + full lifecycle test

**Files:**
- Modify: `move/riskguard/sources/upgrade_registry.move`
- Modify: `move/riskguard/tests/upgrade_registry_tests.move`

- [ ] **Step 1: Write the failing test** (append to test module — full lifecycle)

```move
#[test]
fun full_lifecycle_bumps_version_and_clears_pending() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&admin, &mut reg, DIGEST, package::compatible_policy(), &clk);
    ts::return_to_sender(&sc, admin);

    // Advance past the 72h timelock; permissionless executor drives it.
    sc.next_tx(RANDO);
    clk.set_for_testing(1_000 + TIMELOCK_MS);
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    // test_upgrade stands in for the on-chain Upgrade command.
    let receipt = package::test_upgrade(ticket);
    upgrade_registry::commit_upgrade(&mut reg, receipt);

    // Pending cleared; cap version bumped 1 → 2.
    assert!(!upgrade_registry::has_pending(&reg));
    assert_eq!(upgrade_registry::cap_version(&reg), 2);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sui move test full_lifecycle`
Expected: FAIL — `commit_upgrade` / `cap_version` not found.

- [ ] **Step 3: Implement commit_upgrade + cap_version helper** (append to module)

```move
/// The wrapped cap's current version (read by tests/dashboard).
public fun cap_version(reg: &UpgradeRegistry): u64 {
    package::version(&reg.cap)
}

/// Finalize the upgrade: consume the `UpgradeReceipt` (bumps the cap version) and
/// clear `pending`. Permissionless — must run in the same PTB as `execute_upgrade`
/// and the `Upgrade` command (the receipt is a hot potato).
public fun commit_upgrade(reg: &mut UpgradeRegistry, receipt: UpgradeReceipt) {
    package::commit_upgrade(&mut reg.cap, receipt);
    let PendingUpgrade { digest: _, policy: _, proposed_at_ms: _, epoch: _ } = reg.pending.extract();
}
```

- [ ] **Step 4: Run the full test suite to verify everything passes**

Run: `sui move test`
Expected: PASS — all prior tests (41) + the new upgrade_registry tests (10) green, 0 warnings beyond pre-existing upstream Pyth doc-comments.

- [ ] **Step 5: Commit**

```bash
git add move/riskguard/sources/upgrade_registry.move move/riskguard/tests/upgrade_registry_tests.move
git commit -m "feat(upgrade): commit_upgrade completes lifecycle + full-lifecycle test"
```

---

### Task 7: Reviews + notes

**Files:**
- Modify: `move-notes.md`
- Modify: `tasks/progress.md`

- [ ] **Step 1: Build clean**

Run: `sui move build`
Expected: 0 warnings (besides pre-existing upstream Pyth doc-comments).

- [ ] **Step 2: move-code-quality review**

Invoke the `move-code-quality` skill against `upgrade_registry.move` + the events.move diff. Fix any findings (param order objects-first, doc comments, error-const convention). Re-run `sui move test` after fixes.

- [ ] **Step 3: sui-security-guard scan**

Invoke `sui-security-guard` — secret scan (expect 0) and access-control review of the new entry points.

- [ ] **Step 4: sui-red-team (core access control — required)**

Invoke `sui-red-team` against the 5 vectors from the spec threat model:
1. execute before timelock → `ETimelockActive`
2. re-propose overwriting pending → `EUpgradePending`
3. propose/cancel without AdminCap → cap-gated
4. execute on empty registry → `ENoPending`
5. u64 time underflow/overflow → subtraction-form guard

Document EXPLOITED/DEFENDED per vector. Fix any EXPLOITED before completing.

- [ ] **Step 5: Update notes**

Append to `move-notes.md` a `## 2026-06-03 — upgrade_registry.move` section: purpose, the 5 functions, verified framework API + the hot-potato lifecycle insight, test count, review results, and the residual risks (digest-not-verifiable-at-propose, no on-chain cancel-rate-limit, mainnet 3-of-5 custody is out of contract scope).

Update `tasks/progress.md`: mark upgrade_registry DONE with package test count, suggest next task = `override.move`.

- [ ] **Step 6: Final commit**

```bash
git add move-notes.md tasks/progress.md
git commit -m "docs(upgrade): notes + progress for upgrade_registry"
```

---

## Self-Review

**Spec coverage:**
- Object model (UpgradeRegistry + PendingUpgrade + epoch) → Task 2 ✓
- init_upgrade_registry (AdminCap, one-shot, share) → Task 2 ✓
- propose_upgrade (EUpgradePending + EPolicyTooPermissive fail-fast) → Task 3 ✓
- cancel_upgrade (epoch bump, ENoPending) → Task 4 ✓
- execute_upgrade (ETimelockActive, permissionless, returns ticket, no pending clear) → Task 5 ✓
- commit_upgrade (version bump, clears pending) → Task 6 ✓
- 3 events + emitters → Task 1 ✓
- error codes 40-43 → Tasks 2/3/5 ✓
- 5 threat vectors → Task 7 red-team ✓
- full-lifecycle test (gap closed) → Task 6 ✓

**Type consistency:** `UpgradeRegistry`, `PendingUpgrade`, `has_pending`, `timelock_ms`, `current_epoch`, `cap_version` used consistently across module and tests. `cancel_upgrade` signature includes `&TxContext` (Task 4 Step 3 note + test fix in Step 4). Error consts referenced by `upgrade_registry::EName` in `#[expected_failure]` match definitions.

**Placeholder scan:** No TBD/TODO; every code step has complete code. Review skills in Task 7 are invocations, not code placeholders.

**Note on test count:** "41 prior + 10 new" assumes the current suite is 41 (per progress.md 2026-06-01). Verify actual baseline with `sui move test` before asserting the final number in notes.
