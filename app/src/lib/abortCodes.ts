// Move abort code → operator-readable message. Codes verified against
// move/riskguard/sources/* on 2026-06-12. Unknown codes fall through raw.
const TABLE: Record<number, string> = {
  1: "Borrows are paused for this market",
  2: "Liquidations are paused for this market",
  3: "Deposits are paused for this market",
  4: "Withdraws are paused for this market",
  5: "LTV cap exceeded",
  6: "Oracle price is stale (older than max_staleness_ms)",
  7: "Replay rejected: nonce must be strictly increasing",
  8: "Revert window closed (action no longer revertable)",
  9: "Unknown action id (already reverted or pruned)",
  10: "Pyth confidence interval too wide (exceeds max_conf_bps)",
  11: "Too many pending actions (MAX_PENDING=8) — prune or revert first",
  12: "Cap/policy not bound to this oracle",
  13: "Loosen rate-limited: min_loosen_interval_ms cooldown active",
  14: "Oracle paused (kill switch engaged)",
  20: "Invalid bps value (must be ≤ 10000)",
  21: "Bad config (staleness < 1s or feed id not 32 bytes)",
  22: "Decision sets an undefined flag bit",
  23: "Not protective: override may only lower LTV or add pause flags",
  24: "Override is a no-op (nothing changes)",
  30: "Wrong Pyth feed for this oracle",
  31: "Invalid price (must be positive)",
  40: "An upgrade proposal is already pending — cancel it first",
  41: "No pending upgrade proposal",
  42: "Timelock still active (72h not elapsed)",
  43: "Proposed policy more permissive than the UpgradeCap allows",
  1001: "This cap is not bound to this policy (anti-spoof check)",
};

export function explainAbort(code: number): string {
  return TABLE[code] ?? `Move abort code ${code} (unmapped)`;
}

/** Parses "...MoveAbort(..., <code>)..." out of a wallet/node error string. */
export function extractAbortCode(message: string): number | null {
  const m = message.match(/MoveAbort\(.*,\s*(\d+)\)/s);
  return m ? Number(m[1]) : null;
}

export function explainTxError(message: string): string {
  const code = extractAbortCode(message);
  return code === null ? message : explainAbort(code);
}
