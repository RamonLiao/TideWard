# RiskGuard — Decision Notes

> 為什麼這樣做，不只記做了什麼。下次重啟 chat 直接讀這份。

## 2026-06-11 — Hackathon 走 testnet，不部署 mainnet

- **決策**：Sui Overflow demo 全程用 testnet（已部署 package `0xc91fb4f5…4003`，e2e 對真實 Pyth 驗過）。mainnet 部署不做。
- **Why**：評審看 testnet demo 是常態；RiskGuard 是 risk policy 層，demo 不需真金流；mainnet checklist（pin Pyth/Wormhole rev commit、UpgradeCap 3-of-5 custody）成本高、對 hackathon 零加分。
- **保留**：mainnet checklist 改寫成 README「Production Readiness」章節 —— 展現知道 testnet 與 production 差距，反而加分。
- **已知 testnet 限制（已有 fallback）**：Cetus BUCK/USDC 無 testnet pool → 降級 Pyth + staleness-only（spec P0-2 已記）。
- **下個任務**：前端 dApp（`sui-frontend` + `sui-ts-sdk`）。

## 鎖死的架構基石（不可動搖）

1. **Policy-object-as-gate**：lender 的 borrow/liquidate entry function 必須 import 並呼叫 `riskguard::policy::assert_*_allowed`。這是 RiskGuard 與 EVM 競品的核心差異 — webhook → atomic PTB。
2. **Per-market `RiskPolicy<phantom M>`**：用 phantom type-param 做 compile-time 市場隔離。多市場讀是 parallel-safe（`&` immutable），不會 contention。
3. **Cap-only auth**：no payload signature。Sui tx 簽名已認證 Cap 持有者，雙簽是同把 KMS 鑰匙 = 假隔離。
4. **Events 是 audit trail，不放 ActionLog 物件**：events 本身就是鏈上資料，indexer 物化即可。On-chain 物件只存「revert 需要的最小狀態」（pending_actions snapshot）。

## 三大非對稱原則

| 動作 | 緊縮 / Stop / Propose | 放鬆 / Resume / Execute |
|---|---|---|
| B3 rate limit | 0 冷卻 | 1h cooldown |
| B2 stop/start | `EmergencyStopCap` 單簽秒級 | `AdminCap` 2-of-3 multisig |
| C4 upgrade | Propose 任何時候（gated）| 72h timelock 後 permissionless execute |

**通則**：保護面（緊縮、停、提案）應該快、低摩擦；攻擊面（放鬆、開、推進）應該慢、多人把關。

## 紅隊向量 ↔ 防線對照表

| 攻擊 | 第一防線 | 兜底 |
|---|---|---|
| Executor key 失竊發惡意 loosen | B3 `min_loosen_interval_ms` (1h) | A2 MAX_PENDING + DAO revert(24h) |
| Executor key 失竊發惡意 tighten DoS | B2 indexer 流量告警 → `pause_oracle` | DAO 24h 內 batch revert |
| RG 偷渡 backdoor upgrade | C4 72h timelock + 公開 digest | event 透明 + SaaS SLA |
| Same-type policy spoof | A1 phantom M（compile-time） | A1 lender `policy_id` bind（runtime）|
| BUCK feed staleness | Move `pyth::get_price_no_older_than(60)` | Cetus TWAP secondary（v1）|
| BUCK 低流動性 conf 抖動 | D5 `max_conf_bps` 守衛 | scorer rule layer 拒收高 conf |
| Oracle 抖動 flap | B3 緊縮快放鬆慢自然壓制 | — |
| Replay 舊 score | RiskOracle.nonce 嚴格遞增 | — |
| 攻擊者塞滿 pending vector | A2 `E_TOO_MANY_PENDING` abort | pause + DAO revert |
| AdminCap 全失 | （MVP 無解）| **C4 §10 open**：v1 升級 UpgradeCap 為 3-of-5 含外部 |

## 物件最終形狀（給下個 chat 寫 Move 用）

### 模組樹
```
move/riskguard/sources/
├── policy.move          # RiskPolicy<M>, ActionSnapshot, assert_*_allowed, post_score_and_apply, revert_action
├── oracle.move          # RiskOracle (with active flag), pause_oracle, resume_oracle
├── caps.move            # AdminCap, RiskOraclePublisherCap, EmergencyStopCap, OverrideCap<M>
├── upgrade_registry.move # UpgradeRegistry, UpgradeRequest, propose/execute/cancel
├── events.move
├── errors.move          # E_BORROWS_PAUSED=1 ... E_ORACLE_PAUSED=14, E_WRONG_POLICY=1001
└── admin.move           # init, registry
```

### 關鍵型別 cheat sheet
```move
// flags bitfield
const FLAG_BORROWS_PAUSED:      u8 = 1 << 0;
const FLAG_LIQUIDATIONS_PAUSED: u8 = 1 << 1;
const FLAG_DEPOSITS_PAUSED:     u8 = 1 << 2;
const FLAG_WITHDRAWS_PAUSED:    u8 = 1 << 3;

const MAX_PENDING: u64 = 8;
const DEFAULT_TIMELOCK_MS: u64 = 259_200_000;     // 72h
const DEFAULT_LOOSEN_COOLDOWN_MS: u64 = 3_600_000; // 1h
const DEFAULT_REVERT_WINDOW_MS: u64 = 86_400_000;  // 24h

// 不變式：min_loosen_interval_ms < revert_window_ms
```

## Pyth 整合事實（驗證日期 2026-05-28）

- **不要在 Move 裡呼叫 `pyth::update_single_price_feed`**（upgrade hazard，Pyth 官方明文）。改在 TS 端用 `SuiPythClient.updatePriceFeeds(tx, ...)` 注入 PTB，把 `PriceInfoObject` ID 傳給 Move 函式讀取。
- **BUCK/USD feed**（已驗證存在）：
  - mainnet: `0xfdf28a46570252b25fd31cb257973f865afc5ca2f320439e45d95e0394bc7382`
  - testnet (beta channel, `hermes-beta.pyth.network`): `0xed0899e3a021f1e59031ad365bb3014d78f9ba5556e263692d3508b9272daabf`
- **BUCK 非 sponsored** → 每次 PTB 自帶 update，gas + ~300ms Hermes RTT。對 action PTB 可接受，但 lender 每筆 borrow 不能讀 BUCK price，只能讀 RiskGuard 已算好的 policy 狀態 → 強化「policy as gate」設計。
- **Confidence interval 是 first-class**：低流動性 stable 的 conf 會炸，scorer 與 Move 端都要看 `conf/price` 而非只看 price。

## 棄置但值得記的方案

- **單一 `assert_action_allowed` generic API**：被 A4 砍。理由：liquidation 沒有「requested_ltv」概念，硬塞會逼 lender 餵假值。
- **單一 `paused: bool`**：被 A4 砍。理由：BUCK depeg 想 pause borrow 但留 liquidation，CAPO 想 pause liquidation 但留 borrow，需正交。
- **`ActionLog` shared singleton**：被 A2 砍。理由：雙倍 consensus 寫入、無界儲存、與 events 重複。
- **`PolicyRegistry` shared object 做 discovery**：被 A1 砍。理由：read-mostly 物件吃 consensus 不划算，改 off-chain indexer。
- **Payload signature on `post_score_and_apply`**：被 B2 砍。理由：與 Sui tx sig 同把 KMS 鑰匙，無獨立隔離。
- **對稱 rate limit**：被 B3 砍。理由：緊縮要快，放鬆要慢，對稱是兩邊都吃虧。
- **Upgrade fast path**：被 C4 砍。理由：緊急走 pause_oracle，fast-path 是後門入口。

## 業務 spec 場景 ↔ 鏈上 Decision 對照（驗證 API 表達力）

| 場景 | `new_ltv_bps` | `new_flags` | `reason_code` |
|---|---|---|---|
| BUCK depeg (Stream replay) | 5000 (50%) | `BORROWS \| DEPOSITS` | DEPEG |
| Oracle 偏差 (CAPO replay) | 不變 | `LIQUIDATIONS` | ORACLE_DIVERGENCE |
| Bluefin funding 暴衝 | 降低（margin proxy） | 0 | FUNDING_RUNAWAY |
| 恢復正常 | `ltv_default_bps` | 0 | NORMAL（受 1h cooldown）|

## 2026-05-29 P0 拍板

### UpgradeCap 拆分（Open §10 Q8 收尾）
- **決議**：mainnet pre-launch 把 `UpgradeCap` 升 **3-of-5 multisig（含 2 外部受託人）**；`AdminCap` 維持 2-of-3 ops。
- **理由**：UpgradeCap 可改 bytecode 繞過所有 cap → root-of-trust 必須最慢、最廣簽核。AdminCap 高頻（register market、resume oracle），不能拉外部。72h timelock 已給外部簽核時間，3-of-5 不額外拖延。
- **測試網/MVP**：維持 2-of-3，spec §2.8 標 known limitation。Move 程式碼不變（cap holder 是部署參數）。

### Cetus BUCK/USDC pool ID（Open §10 Q7 收尾）
- **決議**：mainnet 用 `0x4c50ba9d1e60d229800293a4222851c9c3f797aa5ba8a8d32cc67ec7e79fec60`（native USDC, 0.01% fee）；舊版備援 `0xd4573bdd25c629127d54c5671d72a0754ef47767e6c01758d6dc651f57951e7d`（bridged USDC）。
- **Testnet 無 pool**：經 codex 驗證 Cetus SDK config / GitHub 都查不到 testnet BUCK/USDC pool。Testnet MVP fallback ladder 降級為 Pyth + staleness/confidence-only；Cetus adapter 程式碼照寫，testnet 不註冊 pool ID。
- **設計影響**：`oracle.move` 的 Cetus pool 地址做成部署參數（config 物件 or admin setter），不能 hardcode；testnet/mainnet 切換不需重編譯。
- **踩雷紀錄**：gemini 第一次給的兩個 ID 都是假的（mainnet 62 hex 截斷、testnet 是 USDC-ETH pool）。教訓：地址類查詢必走 codex 二次驗證。

## 工具版本鎖（避免下次踩雷）

- Sui Move SDK: `@mysten/sui`（**不是** `@mysten/sui.js`），`Transaction`（不是 `TransactionBlock`）
- Sui 網路：testnet Protocol 124 / v1.72.2
- Pyth Sui SDK: `@pythnetwork/pyth-sui-js`
- Move.toml Pyth dep: `rev = "sui-contract-testnet"`，Wormhole `rev = "sui/testnet"`
- 不用 JSON-RPC（已 deprecated）；executor 走 gRPC，frontend 走 GraphQL beta
