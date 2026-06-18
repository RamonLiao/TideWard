export interface CapSet {
  adminCapId: string | null;
  emergencyCapId: string | null;
  publisherCapId: string | null;
  /** marketType → OverrideCap object id */
  overrideCapIds: Record<string, string>;
}

export function resolveCaps(pkg: string, owned: { objectId: string; type?: string }[]): CapSet {
  const caps: CapSet = { adminCapId: null, emergencyCapId: null, publisherCapId: null, overrideCapIds: {} };
  for (const o of owned) {
    const t = o.type ?? "";
    if (!t.startsWith(`${pkg}::caps::`)) continue; // anti-spoof: exact package
    if (t === `${pkg}::caps::AdminCap`) caps.adminCapId = o.objectId;
    else if (t === `${pkg}::caps::EmergencyStopCap`) caps.emergencyCapId = o.objectId;
    else if (t === `${pkg}::caps::RiskOraclePublisherCap`) caps.publisherCapId = o.objectId;
    else {
      const m = t.match(/::caps::OverrideCap<(.+)>$/);
      if (m) caps.overrideCapIds[m[1]] = o.objectId;
    }
  }
  return caps;
}

export function gate(capId: string | null, capName: string): { enabled: boolean; tooltip: string | null } {
  return capId
    ? { enabled: true, tooltip: null }
    : { enabled: false, tooltip: `Requires ${capName} (not held by connected wallet)` };
}
