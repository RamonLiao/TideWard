import { describe, it, expect } from "vitest";
import { feedIdToBytes, SUI_USD_FEED_ID } from "../src/config.js";

describe("config feed id", () => {
  it("SUI/USD feed decodes to exactly 32 bytes", () => {
    const bytes = feedIdToBytes(SUI_USD_FEED_ID);
    expect(bytes).toHaveLength(32);
    expect(bytes.every((b) => b >= 0 && b <= 255)).toBe(true);
  });

  it("rejects a wrong-length feed id", () => {
    expect(() => feedIdToBytes("0x1234")).toThrow(/32 bytes/);
  });
});
