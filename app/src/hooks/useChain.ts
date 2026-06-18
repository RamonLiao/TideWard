import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCurrentAccount, useCurrentClient, useDAppKit } from "@mysten/dapp-kit-react";
import { Transaction } from "@mysten/sui/transactions";
import { queryPackageEvents } from "../lib/rpc";
import { parsePolicy, parseOracle, parseRegistry, parseEvent } from "../lib/parsers";
import { resolveCaps, type CapSet } from "../lib/caps";
import { explainTxError } from "../lib/abortCodes";
import { PKG, REGISTRY_ID, type MarketConfig } from "../config";

/* eslint-disable @typescript-eslint/no-explicit-any */

const POLL_MS = 7000;

/** Single adaptation point between the gRPC response and the field parsers.
 * Verified against installed @mysten/sui 2.17: core.getObject({include:{json:true}})
 * returns the Move fields under `res.object.json`. (content:true would return raw
 * BCS bytes, not a fields record.) Throws loudly rather than returning garbage. */
function extractFields(res: any, what: string): Record<string, any> {
  const f = res?.object?.json;
  if (!f || typeof f !== "object") throw new Error(`${what}: cannot locate fields in gRPC response — update extractFields()`);
  return f;
}

function useObjectQuery<T>(key: string, objectId: string, parse: (f: Record<string, any>) => T) {
  const client = useCurrentClient();
  return useQuery({
    queryKey: [key, objectId],
    queryFn: async () => {
      const res = await (client as any).core.getObject({ objectId, include: { json: true } });
      return parse(extractFields(res, key));
    },
    refetchInterval: POLL_MS,
  });
}

export function usePolicy(m: MarketConfig) {
  return useObjectQuery("policy", m.policyId, parsePolicy);
}

export function useOracle(m: MarketConfig) {
  return useObjectQuery("oracle", m.oracleId, parseOracle);
}

export function useRegistry() {
  return useObjectQuery("registry", REGISTRY_ID, parseRegistry);
}

export function useEvents() {
  return useQuery({
    queryKey: ["events", PKG],
    queryFn: async () => (await queryPackageEvents(PKG)).data.map(parseEvent),
    refetchInterval: POLL_MS,
  });
}

export function useCaps(): { caps: CapSet; isPending: boolean } {
  const account = useCurrentAccount();
  const client = useCurrentClient();
  const q = useQuery({
    queryKey: ["caps", account?.address],
    queryFn: async () => {
      // List all owned objects and filter client-side. This avoids relying on a
      // gRPC type-filter matching the generic OverrideCap<M> by prefix (unverified);
      // resolveCaps already does exact, anti-spoof type matching. Bounded to a few pages.
      const flat: { objectId: string; type?: string }[] = [];
      let cursor: string | null = null;
      for (let i = 0; i < 5; i++) {
        const page: any = await (client as any).core.listOwnedObjects({ owner: account!.address, cursor });
        for (const o of page.objects ?? []) flat.push({ objectId: o.objectId ?? o.id, type: o.type });
        if (!page.hasNextPage) break;
        cursor = page.cursor;
      }
      return resolveCaps(PKG, flat);
    },
    enabled: !!account,
    refetchInterval: 30_000,
  });
  return { caps: q.data ?? resolveCaps(PKG, []), isPending: q.isPending && !!account };
}

/** Sign+execute, wait for indexing, refresh all chain queries. Throws human-readable errors. */
export function useExecute() {
  const dAppKit = useDAppKit();
  const client = useCurrentClient();
  const queryClient = useQueryClient();
  return async (tx: Transaction) => {
    try {
      const result: any = await dAppKit.signAndExecuteTransaction({ transaction: tx });
      if (result.FailedTransaction) {
        throw new Error(explainTxError(JSON.stringify(result.FailedTransaction)));
      }
      const digest: string = result.Transaction.digest;
      await (client as any).core.waitForTransaction({ digest });
      await queryClient.invalidateQueries(); // refresh policy/oracle/registry/events/caps
      return digest;
    } catch (e) {
      throw new Error(explainTxError(e instanceof Error ? e.message : String(e)));
    }
  };
}
