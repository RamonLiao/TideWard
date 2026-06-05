# override.move — DAO Protective Override Design

> Date: 2026-06-05
> Status: approved (brainstorming) → ready for writing-plans
> Scope: 1 new module `override.move` + `policy.move` (+1 `public(package)` fn) + `events.move` (+1 event/emitter). Zero changes to oracle / admin / upgrade_registry / pyth_adapter.

## 1. Problem

The original architecture spec listed `override.move = "OverrideCap + revert flow"`, but that
responsibility is **already implemented**: `OverrideCap<M>` lives in `caps.move` and the revert
flow (`revert_action`) lives in `policy.move` (50 passed, red-team O2 DEFENDED). Re-creating it
would be pure code movement that breaks a tested module boundary.

The genuine gap: the DAO can only **undo** oracle-pushed pending actions (`revert_action`). There
is **no proactive protective path**. To force-tighten LTV or force-pause a specific market today,
the DAO must either wait for the oracle to push or use `EmergencyStopCap` (which halts the entire
oracle — too coarse and does not change policy state). `override.move` fills this: a human-driven,
**protective-only** override that complements revert.

## 2. Design

### 2.1 Module boundary (Approach A)

Mirror the existing `oracle::post_score_and_apply → policy::apply_decision` pattern. The mutation
must touch `RiskPolicy` private fields (`ltv_bps`, `flags`, `pending_actions`, `next_action_id`),
so it lives in `policy.move` as a new `public(package)` fn. `override.move` is the public
authorization + protective-check surface.

- `override.move` → `policy.move` (clean DAG; no new edges).
- `revert_action` stays in `policy.move` untouched.
- The override snapshot is pushed onto the **same** `pending_actions` stack, so `revert_action`
  reverts it with **zero new revert code**.

### 2.2 Public entry — `override.move`

```move
public fun force_protect<M>(
    policy: &mut RiskPolicy<M>,
    cap: &OverrideCap<M>,
    new_ltv_bps: u16,
    new_flags: u8,
    reason_code: u8,
    clock: &Clock,
    ctx: &TxContext,
)
```

**Responsibility split (architecture review M1): `force_protect` owns "what counts as a valid
protective override" (override semantics); `policy::apply_override` owns "how to safely record a
state change" (storage mechanics).** This avoids a degenerate wrapper — unlike a pure forwarder,
`force_protect` carries the protective decision, mirroring how `oracle::post_score_and_apply`
carries real checks before delegating to `apply_decision`. The split is feasible because
`policy.move` exposes the needed reads as public getters (`current_ltv_cap`, `current_flags`).

`force_protect` steps:
1. **Anti-spoof (A1 runtime leg):** `assert!(caps::override_policy_id(cap) == object::id(policy), EWrongPolicy)`.
2. **Monotonic protective** (read current state via public getters):
   - `let cur_ltv = policy::current_ltv_cap(policy); let cur_flags = policy::current_flags(policy);`
   - `assert!(new_ltv_bps <= cur_ltv, ENotProtective)` — LTV may only drop.
   - `assert!(cur_flags & new_flags == cur_flags, ENotProtective)` — every currently-set flag
     stays set (new ⊇ current); flags may only be added, never cleared.
3. **No-op reject:** `assert!(new_ltv_bps != cur_ltv || new_flags != cur_flags, EOverrideNoop)`.
4. Delegate to `policy::apply_override(policy, new_ltv_bps, new_flags, reason_code, clock, ctx)`.

`ENotProtective` / `EOverrideNoop` are defined in `policy.move` (with the other policy errors) and
referenced from `override.move`. Move has no cross-module `const`, so `override.move` re-declares
the same `u64` values locally with a comment pointing at policy.move as the source of truth (same
pattern the codebase already uses for stable cross-component error numbers).

### 2.3 Mutation — `policy.move` `apply_override` (new `public(package)`)

```move
public(package) fun apply_override<M>(
    policy: &mut RiskPolicy<M>,
    new_ltv_bps: u16,
    new_flags: u8,
    reason_code: u8,
    clock: &Clock,
    ctx: &TxContext,
)
```

Owns storage mechanics + structural validation only (the override-semantics checks already ran in
`force_protect`). No `cap` param: this is `public(package)`, callable only from within the package,
and `force_protect` is its sole caller having already done cap binding. Steps:
1. `assert!(new_flags & (KNOWN_FLAGS ^ 0xFFu8) == 0, EInvalidFlags)` — no reserved bits
   (`KNOWN_FLAGS` is private to policy.move, so this structural check lives here).
2. `let now = clock.timestamp_ms();`
3. `prune_expired(policy, now)` — free slots whose revert window closed.
4. `assert!(policy.pending_actions.length() < MAX_PENDING, ETooManyPending)` — anti-griefing bound.
5. Push `ActionSnapshot { action_id: policy.next_action_id, kind: KIND_OVERRIDE,
   prev_ltv_bps: policy.ltv_bps, prev_flags: policy.flags, reason_code, ts_ms: now }`;
   bump `next_action_id`.
6. Write `policy.ltv_bps = new_ltv_bps; policy.flags = new_flags;`.
7. `events::emit_override_applied(...)`.

**No B3 rate limit:** force_protect is monotonic-protective (only tightens), so the loosening
throttle does not apply. Tightening is already free in `apply_decision`.

**Layering note:** the monotonic check is enforced *only* in `force_protect`, the sole caller. This
is acceptable because `apply_override` is `public(package)` (no external bypass), and matches the
existing `oracle → apply_decision` split where `apply_decision` trusts the oracle's prior checks.
A red-team test asserts the monotonic guard (vectors 1–2 in §3.2) to lock the invariant.

### 2.4 New constants / errors (policy.move)

```move
const KIND_OVERRIDE: u8 = 3;          // ActionSnapshot kind: human protective override
const ENotProtective: u64 = 23;       // override would loosen (raise LTV or clear a flag)
const EOverrideNoop: u64 = 24;        // override changes nothing
```

Reused: `EWrongPolicy=1001`, `EInvalidFlags=22`, `ETooManyPending=11`. Codes 23/24 are free in the
policy range (used: 1-5,8,9,11,13,20,21,22,1001; pyth_adapter holds 30,31). Plain `u64` per the
module's existing cross-component-contract convention (not `#[error]`).

### 2.5 New event (events.move, append-only)

```move
public struct OverrideApplied has copy, drop {
    market: TypeName,
    action_id: u64,
    prev_ltv: u16,
    new_ltv: u16,
    prev_flags: u8,
    new_flags: u8,
    reason_code: u8,  // L1: carried in the event so the indexer audits the why without reading the object
    by: address,
    ts_ms: u64,
}

public(package) fun emit_override_applied(
    market: TypeName, action_id: u64,
    prev_ltv: u16, new_ltv: u16, prev_flags: u8, new_flags: u8,
    reason_code: u8, by: address, ts_ms: u64,
)
```

`by = ctx.sender()`. The indexer distinguishes human overrides (`OverrideApplied` /
`KIND_OVERRIDE`) from oracle actions (`ActionExecuted`).

## 3. Security

### 3.1 Blast-radius bound (OverrideCap compromise)

The monotonic-protective rule is the core mitigation for threat §3 (DAO override key compromise):
a stolen `OverrideCap` can, via `force_protect`, **only over-tighten** (lower LTV / set pause
flags) — never loosen to enable bad borrows. Over-tightening is recoverable: the DAO/admin
`revert_action`s it, or the oracle re-applies a looser-but-valid stance. Combined with per-market
`OverrideCap<M>` scoping and k-of-n multisig (2-of-3 → 3-of-5), blast radius is bounded.

### 3.2 Red-team vectors (≤5, to be tested)

1. **Monotonic bypass — raise LTV:** `new_ltv > current` → must abort `ENotProtective`.
2. **Monotonic bypass — clear a flag:** drop a currently-set pause bit → must abort `ENotProtective`.
3. **Wrong-cap (spoof):** `OverrideCap` bound to policy B used on policy A → `EWrongPolicy`.
4. **Reserved-flag injection:** `new_flags` sets bit 4..7 → `EInvalidFlags`.
5. **DoS via pending flood:** `force_protect` respects `MAX_PENDING` (aborts `ETooManyPending`
   when full after prune) — same bound as `apply_decision`; multisig is not a griefing source.

### 3.3 Deliberate tradeoffs (known)

- **MAX_PENDING full → abort, not bypass.** Keeps the anti-griefing invariant uniform across all
  mutation paths. In an emergency a full queue of 8 un-expired actions is rare; the DAO can
  `revert_action` to free a slot or wait for prune. Accepted for v0; revisit if ops hit it.
- **Override is itself revertable** (pushed to `pending_actions`). Intended: lets the DAO unwind
  its own panic-tighten within the window, and keeps one uniform audit/revert surface.

## 4. Files touched

| File | Change |
|---|---|
| `sources/override.move` | NEW — `force_protect<M>` |
| `sources/policy.move` | +`public(package) apply_override`, +`KIND_OVERRIDE`, +`ENotProtective`, +`EOverrideNoop` |
| `sources/events.move` | +`OverrideApplied` struct + `emit_override_applied` |
| `tests/override_tests.move` | NEW — ~8 tests |

Zero changes to `oracle.move`, `admin.move`, `caps.move`, `upgrade_registry.move`, `pyth_adapter.move`.

## 5. Test plan (`tests/override_tests.move`, ~8)

1. `force_tighten_ltv` — lower LTV, assert state + `OverrideApplied` + snapshot pushed.
2. `force_set_flag` — set a pause bit, assert state.
3. `force_combined` — lower LTV **and** add flag in one call.
4. `reject_loosen_ltv` — `expected_failure(ENotProtective)`.
5. `reject_clear_flag` — `expected_failure(ENotProtective)`.
6. `reject_noop` — same ltv + flags → `expected_failure(EOverrideNoop)`.
7. `reject_wrong_cap` — cap bound to another policy → `expected_failure(EWrongPolicy)`.
8. `reject_reserved_flag` — reserved bit → `expected_failure(EInvalidFlags)`.
9. `override_then_revert` — integration: `force_protect` then `revert_action` rewinds to pre-image.
10. `reject_when_pending_full` — fill MAX_PENDING → `expected_failure(ETooManyPending)`.

(Final count determined by `sui move test`; baseline is 50 passed.)

## 6. Out of scope

- No new cap (reuses `OverrideCap<M>`).
- No loosening path (deliberate — that is the oracle's job, throttled by B3).
- No MAX_PENDING bypass / dynamic-field overflow store.
- No frontend / TS integration (separate task).
