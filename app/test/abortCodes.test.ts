import { describe, it, expect } from "vitest";
import { explainAbort, extractAbortCode } from "../src/lib/abortCodes";

describe("explainAbort", () => {
  it("maps known codes to human messages (intent: operator must understand chain rejections)", () => {
    expect(explainAbort(7)).toMatch(/nonce/i);        // EReplay
    expect(explainAbort(23)).toMatch(/protective/i);  // ENotProtective
    expect(explainAbort(42)).toMatch(/timelock/i);    // ETimelockActive
    expect(explainAbort(1001)).toMatch(/cap.*bound|bound.*cap/i); // EWrongPolicy
  });
  it("falls back to raw code for unknown values (fail loud, never hide)", () => {
    expect(explainAbort(9999)).toContain("9999");
  });
});

describe("extractAbortCode", () => {
  it("pulls the code out of a MoveAbort error string", () => {
    const msg = 'MoveAbort(MoveLocation { module: ModuleId { address: c91f..., name: Identifier("oracle") }, function: 3, instruction: 18, function_name: Some("post_score_and_apply") }, 7) in command 2';
    expect(extractAbortCode(msg)).toBe(7);
  });
  it("returns null when no abort code present", () => {
    expect(extractAbortCode("InsufficientGas")).toBeNull();
  });
});
