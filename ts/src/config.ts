// All verified Sui-testnet constants for the RiskGuard Pyth e2e (spec §3).
// Do NOT use mainnet feed ids here — testnet SUI/USD differs from mainnet.

export const NETWORK = "testnet" as const;

export const PYTH_STATE_ID =
  "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c";
export const WORMHOLE_STATE_ID =
  "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790";
export const HERMES_ENDPOINT = "https://hermes-beta.pyth.network";

// SUI/USD testnet beta feed (NOT mainnet 0x23d7...5744).
export const SUI_USD_FEED_ID =
  "0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";

export const CLOCK_ID = "0x6";

// Phantom market marker — any published type works; SUI needs no new Move module.
export const MARKET_TYPE = "0x2::sui::SUI";

// register_market config (spec §6). Short revert_window so repeated e2e runs
// prune pending snapshots and never hit MAX_PENDING=8.
export const REGISTER = {
  ltvDefaultBps: 5000,
  revertWindowMs: 60_000,        // 1 min; min_loosen must be < this
  minLoosenIntervalMs: 5_000,
  maxConfBps: 10_000,            // MAX — do not reject on confidence (decode test)
  maxStalenessMs: 60_000,        // /1000 = 60s for get_price_no_older_than
};

// E2E decision: tighten LTV (lower cap) so it's NOT a loosen → no B3 throttle on re-runs.
export const E2E = {
  newLtvBps: 4000,
  newFlags: 0,                   // no flag bits set
  reasonCode: 1,
  scoreBps: 7777,                // distinctive value we assert reaches state
};

// Move function targets, parameterized by package id at call time.
export const fq = (pkg: string, mod: string, fn: string) => `${pkg}::${mod}::${fn}` as const;

// Strip 0x and decode a hex feed id to a byte array for tx.pure.vector("u8", ...).
export function feedIdToBytes(feedId: string): number[] {
  const hex = feedId.startsWith("0x") ? feedId.slice(2) : feedId;
  if (hex.length !== 64) throw new Error(`feed id must be 32 bytes, got ${hex.length / 2}`);
  const out: number[] = [];
  for (let i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}
