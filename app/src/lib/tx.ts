import { Transaction } from "@mysten/sui/transactions";
import { CLOCK_ID } from "../config";

const fq = (pkg: string, mod: string, fn: string) => `${pkg}::${mod}::${fn}` as const;

export function buildPause(pkg: string, oracleId: string, emergencyCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "oracle", "pause_oracle"),
    arguments: [tx.object(oracleId), tx.object(emergencyCapId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export function buildResume(pkg: string, oracleId: string, adminCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "oracle", "resume_oracle"),
    arguments: [tx.object(oracleId), tx.object(adminCapId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export interface ForceProtectInput { newLtvBps: number; newFlags: number; reasonCode: number; }

export function buildForceProtect(
  pkg: string, policyId: string, overrideCapId: string, marketType: string, input: ForceProtectInput,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "override", "force_protect"),
    typeArguments: [marketType],
    arguments: [
      tx.object(policyId), tx.object(overrideCapId),
      tx.pure.u16(input.newLtvBps), tx.pure.u8(input.newFlags), tx.pure.u8(input.reasonCode),
      tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function buildRevert(
  pkg: string, policyId: string, overrideCapId: string, marketType: string, actionId: number,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "policy", "revert_action"),
    typeArguments: [marketType],
    arguments: [tx.object(policyId), tx.object(overrideCapId), tx.pure.u64(actionId), tx.object(CLOCK_ID)],
  });
  return tx;
}

export function buildProposeUpgrade(
  pkg: string, registryId: string, adminCapId: string, digest: number[], policy: number,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "upgrade_registry", "propose_upgrade"),
    arguments: [
      tx.object(registryId), tx.object(adminCapId),
      tx.pure.vector("u8", digest), tx.pure.u8(policy), tx.object(CLOCK_ID),
    ],
  });
  return tx;
}

export function buildCancelUpgrade(pkg: string, registryId: string, adminCapId: string): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: fq(pkg, "upgrade_registry", "cancel_upgrade"),
    arguments: [tx.object(registryId), tx.object(adminCapId)],
  });
  return tx;
}
