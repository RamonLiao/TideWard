import { describe, it, expect } from "vitest";
import { validateForceProtect } from "../src/lib/monotonic";

// Intent: mirror override.move's monotonic-protective rule so the submit
// button can be disabled with an explanation BEFORE the chain aborts (23/24).
// The contract remains the source of truth.
describe("validateForceProtect", () => {
  const cur = { ltvBps: 4000, flags: 0b0001 };

  it("allows lowering LTV", () => {
    expect(validateForceProtect(cur, 3000, 0b0001)).toEqual({ ok: true });
  });
  it("allows adding a flag", () => {
    expect(validateForceProtect(cur, 4000, 0b0011)).toEqual({ ok: true });
  });
  it("rejects raising LTV (would loosen)", () => {
    const r = validateForceProtect(cur, 5000, 0b0001);
    expect(r.ok).toBe(false);
    expect(r.ok === false && r.reason).toMatch(/lower|raise/i);
  });
  it("rejects clearing a flag (would loosen)", () => {
    const r = validateForceProtect(cur, 4000, 0b0000);
    expect(r.ok).toBe(false);
  });
  it("rejects a no-op (contract aborts 24)", () => {
    const r = validateForceProtect(cur, 4000, 0b0001);
    expect(r.ok).toBe(false);
    expect(r.ok === false && r.reason).toMatch(/no-?op|nothing/i);
  });
  it("rejects undefined flag bits (contract KNOWN_FLAGS = bits 0-3)", () => {
    const r = validateForceProtect(cur, 3000, 0b10001);
    expect(r.ok).toBe(false);
  });
  it("rejects ltv > MAX_BPS and non-integer/negative input (monkey-proof)", () => {
    expect(validateForceProtect(cur, 10001, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, -1, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, 39.5, 0b0001).ok).toBe(false);
    expect(validateForceProtect(cur, Number.NaN, 0b0001).ok).toBe(false);
  });
});
