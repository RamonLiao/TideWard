import { describe, it, expect } from "vitest";
import { resolveCaps, gate } from "../src/lib/caps";

// Intent: buttons must mirror contract auth exactly — pause needs
// EmergencyStopCap, resume needs AdminCap, override/revert need OverrideCap<M>.
const PKG = "0xPKG";
describe("resolveCaps", () => {
  it("maps owned objects to cap ids", () => {
    const caps = resolveCaps(PKG, [
      { objectId: "0x1", type: `${PKG}::caps::AdminCap` },
      { objectId: "0x2", type: `${PKG}::caps::EmergencyStopCap` },
      { objectId: "0x3", type: `${PKG}::caps::OverrideCap<0x2::sui::SUI>` },
    ]);
    expect(caps.adminCapId).toBe("0x1");
    expect(caps.emergencyCapId).toBe("0x2");
    expect(caps.overrideCapIds["0x2::sui::SUI"]).toBe("0x3");
  });
  it("ignores foreign-package lookalikes (anti-spoof: type prefix must match PKG)", () => {
    const caps = resolveCaps(PKG, [{ objectId: "0x9", type: "0xEVIL::caps::AdminCap" }]);
    expect(caps.adminCapId).toBeNull();
  });
});

describe("gate", () => {
  const none = resolveCaps(PKG, []);
  it("disabled with the missing-cap name in the tooltip", () => {
    const g = gate(none.emergencyCapId, "EmergencyStopCap");
    expect(g.enabled).toBe(false);
    expect(g.tooltip).toContain("EmergencyStopCap");
  });
  it("enabled when cap held", () => {
    expect(gate("0x2", "EmergencyStopCap")).toEqual({ enabled: true, tooltip: null });
  });
});
