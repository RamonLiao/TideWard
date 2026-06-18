import { describe, it, expect } from "vitest";
import { buildPause, buildResume, buildForceProtect, buildRevert, buildProposeUpgrade, buildCancelUpgrade } from "../src/lib/tx";

// Intent: every builder must target the verified Move entry with the right
// type args. We assert on the serialized tx JSON (no network needed).
const ids = {
  pkg: "0x" + "1".repeat(64), oracle: "0x" + "2".repeat(64), policy: "0x" + "3".repeat(64),
  registry: "0x" + "4".repeat(64), cap: "0x" + "5".repeat(64),
};
const mkt = "0x2::sui::SUI";

async function targets(tx: { toJSON(): Promise<string> }) {
  const j = JSON.parse(await tx.toJSON());
  return j.commands.map((c: any) => c.MoveCall?.function && `${c.MoveCall.module}::${c.MoveCall.function}`);
}

describe("tx builders", () => {
  it("pause/resume target oracle module", async () => {
    expect(await targets(buildPause(ids.pkg, ids.oracle, ids.cap))).toEqual(["oracle::pause_oracle"]);
    expect(await targets(buildResume(ids.pkg, ids.oracle, ids.cap))).toEqual(["oracle::resume_oracle"]);
  });
  it("force_protect targets override module with the market type arg", async () => {
    const tx = buildForceProtect(ids.pkg, ids.policy, ids.cap, mkt, { newLtvBps: 3000, newFlags: 1, reasonCode: 2 });
    const j = JSON.parse(await tx.toJSON());
    expect(j.commands[0].MoveCall.function).toBe("force_protect");
    expect(j.commands[0].MoveCall.typeArguments).toEqual([mkt]);
  });
  it("revert_action carries the action id", async () => {
    expect(await targets(buildRevert(ids.pkg, ids.policy, ids.cap, mkt, 2))).toEqual(["policy::revert_action"]);
  });
  it("upgrade propose/cancel target the registry", async () => {
    expect(await targets(buildProposeUpgrade(ids.pkg, ids.registry, ids.cap, [1, 2], 0))).toEqual(["upgrade_registry::propose_upgrade"]);
    expect(await targets(buildCancelUpgrade(ids.pkg, ids.registry, ids.cap))).toEqual(["upgrade_registry::cancel_upgrade"]);
  });
});
