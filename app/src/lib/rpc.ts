// DEPRECATION ISOLATION: this is the only JSON-RPC touchpoint in the app.
// gRPC (SDK v2) has no historical event query — SubscribeEvents streams
// forward only. Replace this file when gRPC/indexer exposes event history.
import { RPC_URL } from "../config";

let nextId = 1;

async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`RPC ${method}: ${body.error.message}`);
  return body.result as T;
}

/** All riskguard events live in the events module — one query covers the ticker. */
export function queryPackageEvents(pkg: string, limit = 50) {
  return rpc<{ data: { id: { txDigest: string; eventSeq: string }; type: string; parsedJson: Record<string, unknown>; timestampMs?: string }[] }>(
    "suix_queryEvents",
    [{ MoveEventModule: { package: pkg, module: "events" } }, null, limit, true /* descending */],
  );
}
