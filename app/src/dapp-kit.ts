import { createDAppKit } from "@mysten/dapp-kit-react";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { RPC_URL } from "./config";

// gRPC-web endpoint. Testnet fullnode serves gRPC v2 on the same host.
// RPC_URL (JSON-RPC) is reused only as the base host; if the gRPC endpoint
// diverges, change ONLY this baseUrl.
export const dAppKit = createDAppKit({
  networks: ["testnet"],
  defaultNetwork: "testnet",
  createClient: (network) => new SuiGrpcClient({ network, baseUrl: RPC_URL }),
});

declare module "@mysten/dapp-kit-react" {
  interface Register {
    dAppKit: typeof dAppKit;
  }
}
