export const KNOWN_FLAGS = 0b1111; // bits 0-3, mirrors policy.move KNOWN_FLAGS
const MAX_BPS = 10_000;

export const FLAG_LABELS: { bit: number; label: string }[] = [
  { bit: 1 << 0, label: "Borrows paused" },
  { bit: 1 << 1, label: "Liquidations paused" },
  { bit: 1 << 2, label: "Deposits paused" },
  { bit: 1 << 3, label: "Withdraws paused" },
];

export type Validation = { ok: true } | { ok: false; reason: string };

export function validateForceProtect(
  current: { ltvBps: number; flags: number },
  newLtvBps: number,
  newFlags: number,
): Validation {
  if (!Number.isInteger(newLtvBps) || newLtvBps < 0 || newLtvBps > MAX_BPS)
    return { ok: false, reason: `LTV must be an integer in [0, ${MAX_BPS}] bps` };
  if (!Number.isInteger(newFlags) || newFlags < 0 || (newFlags & ~KNOWN_FLAGS) !== 0)
    return { ok: false, reason: "Flags contain undefined bits (only bits 0-3 exist)" };
  if (newLtvBps > current.ltvBps)
    return { ok: false, reason: "Override may only LOWER the LTV cap, not raise it" };
  if ((current.flags & newFlags) !== current.flags)
    return { ok: false, reason: "Override may only ADD pause flags, not clear them" };
  if (newLtvBps === current.ltvBps && newFlags === current.flags)
    return { ok: false, reason: "No-op: nothing changes (chain would abort with code 24)" };
  return { ok: true };
}
