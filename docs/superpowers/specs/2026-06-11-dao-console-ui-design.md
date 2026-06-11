# RiskGuard DAO 操作台 — UI Design Spec

> Date: 2026-06-11
> Status: approved by user (brainstorming session)
> Scope: 前端 dApp（testnet demo for Sui Overflow hackathon）。決策背景見 `tasks/notes.md` 2026-06-11（hackathon 全程 testnet，不部署 mainnet）。

## 1. 目標與定位

真實 **DAO operator 操作台**（非評審導向 demo dashboard）：讓持有 Cap 的 operator 監控 market 風險狀態、執行 emergency pause/resume、force_protect override、revert pending actions、管理 upgrade timelock。

MVP 功能範圍（全部四項，user 已選）：

1. Market 狀態總覽
2. Emergency 控制（pause/resume）
3. Override + Revert
4. Upgrade Timelock 管理

## 2. 技術棧

- React 18 + Vite + TypeScript，新子專案 `app/`（與現有 `ts/` deploy/e2e scripts 分離）
- `@mysten/dapp-kit`（wallet 連接、`useSuiClientQuery`、TanStack Query 內建）
- `@mysten/sui`（Transaction/PTB 構建）
- pnpm（與 `ts/` 一致，node 24）
- Testnet only。合約 ids 來源：`ts/.deployed.json`（gitignored）→ build-time 以 env/config 注入 `app/`（`app/src/config.ts` 讀 `VITE_*` env 或 import 同 schema 的 config 檔；不得 hardcode id 進 source）

## 3. Layout（已選方案 A：Sidebar + 分頁）

```
┌──────────────────────────────────────────────────────┐
│ ⬡ RISKGUARD │ oracle 狀態燈 │ [⏸ EMERGENCY PAUSE] │ wallet │  ← 常駐頂列
├──────────┬───────────────────────────────────────────┤
│ Markets  │                                           │
│ Emergency│           當前分頁內容                     │
│ Override │                                           │
│ Upgrades │                                           │
├──────────┴───────────────────────────────────────────┤
│ EVENT STREAM ticker（全域事件流）                      │
└──────────────────────────────────────────────────────┘
```

- **頂列 Emergency Pause**：任何頁面一鍵 pause（多 market 時開 market 選擇 popover）。緊急動作摩擦最小化，對應合約「保護面要快」原則。
- **Markets 頁**：支援 **list ↔ card grid 切換**（user 要求：item 多時 grid 較好顯示）。每個 market 顯示：LTV (bps)、flags、latest_score_bps、oracle active/staleness、pending count。
- **Emergency / Override 頁**：跨 market 總覽 + 對應事件歷史（OraclePaused/OracleResumed；OverrideApplied）。操作本身在 drawer（見 §4）。
- **Upgrades 頁**：見 §7。

## 4. 操作入口（已選方案 A：Market 卡片 → 右側 Drawer）

點 market 卡片滑出右側 drawer，包含：

- 完整狀態（LTV、flags 逐 bit 顯示、score、staleness、oracle 狀態）
- **pending actions 列表**：每筆顯示 kind/old→new 值/時間，帶 `Revert` 按鈕 + 24h revert window 倒數；過期項標灰
- **Pause / Resume** 按鈕（依 cap 啟用，見 §5）
- **Force Protect 表單**：new LTV + flags 輸入。前端先驗 **monotonic-protective**（只准降 LTV / 只准加 flag bit）：違反時 disable 送出鈕並 inline 說明原因。最終仍由合約把關，前端驗證只是 UX。

## 5. 權限模型（cap-driven UI）

- 連錢包後以 `getOwnedObjects`（StructType filter）查持有的 `AdminCap` / `EmergencyStopCap` / `OverrideCap<M>` / `RiskOraclePublisherCap`
- 所有寫入按鈕依 cap 持有自動啟用/禁用；禁用時 tooltip 註明缺哪個 cap
- 直接映射合約非對稱設計：pause = EmergencyStopCap 單簽即按；resume = AdminCap；force_protect = OverrideCap<M>（per-market）；upgrade propose/cancel = AdminCap，execute/commit = permissionless（任何已連錢包可按）

## 6. 資料流

- **讀**：`getObject`（showContent）輪詢 `RiskPolicy<M>` / `RiskOracle` / `UpgradeRegistry`，間隔 5–10s（TanStack Query refetchInterval）
- **事件**：`queryEvents`（by MoveEventType）訂閱 9 種事件：`ActionExecuted` / `ActionReverted` / `OverrideApplied` / `OraclePaused` / `OracleResumed` / `MarketRegistered` + upgrade 3 events（propose/cancel/commit）。全域底部 ticker + drawer 內 per-market 過濾
- **寫**：PTB 經 dapp-kit `signAndExecuteTransaction`；成功後 `waitForTransaction` 再 invalidate queries（fullnode read-after-write 踩雷已知，見 move-notes 2026-06-01）
- **錯誤映射**：Move abort code → 人話。對照表維護於單一 module（`app/src/lib/abortCodes.ts`），涵蓋已知 codes（如 `EReplay=7`、`EStaleOracle=6`、`EInvalidFlags=22`、`EWrongFeed=30`、`EInvalidPrice=31`、`EUpgradePending=40`–`EPolicyTooPermissive=43` 等）；未知 code 顯示原始碼值

## 7. Upgrades 頁

- 無 pending：顯示 registry 現狀（cap version、epoch）+ AdminCap 持有者可 propose（digest + policy 輸入）
- 有 pending：**72h timelock 霓虹倒數環**；到期前 AdminCap 可 cancel；到期後 `Execute` 亮起（permissionless）
- execute→commit 是同 PTB 原子閉環（hot-potato），UI 上是單一「Execute Upgrade」動作
- 註：testnet demo 中 upgrade bytecode 來源簡化 — UI 只做 propose/cancel/倒數/execute 的狀態管理展示，execute 實跑需配 CLI build 的 bytecode（文件註明）

## 8. 視覺風格（已確認：Dark Mission Control × Tron）

- 底色 `#050a0f` + 微發光格線背景（`rgba(0,229,255,.05)` 28px grid）
- 語意色：**霓虹青 `#00e5ff` = 正常/品牌**、**橘 `#ff6b35` = 警示/pending/override**、**紅 `#ff3b3b` = paused/危險**、綠 `#00ff9f` = active 燈
- monospace 數字 + text-shadow/box-shadow 光暈；卡片半透明青底 + 發光邊框
- 參考 mockup：`.superpowers/brainstorm/78696-1781191029/content/visual-style-tron.html`（local，未進 git）

## 9. 測試策略

- **Vitest 組件/單元測**，聚焦三個業務規則所在（測 intent）：
  1. cap-gating：無 cap → 按鈕禁用 + tooltip；有 cap → 啟用
  2. monotonic-protective 前端驗證：升 LTV / 移除 flag bit → blocked
  3. abort code 映射：已知 code → 人話；未知 → 原始值
- **E2E**：手動 walkthrough 對 testnet 部署（hackathon 範圍不上 Playwright CI）。走完：連錢包 → 看狀態 → pause/resume → force_protect → revert → upgrade propose/cancel
- Monkey testing（per `.claude/rules/test.md`）：表單灌極端值（u64 max、0、負號字串、超長 flags）確認前端不炸、合約 abort 有被映射

## 10. 刻意不做（YAGNI）

- lender 模擬視角 / borrower flow
- indexer 後端（直接 fullnode query；event 量在 demo 規模下夠用）
- responsive mobile、i18n、dark/light 切換（只有 Tron dark）
- 真實 upgrade bytecode pipeline（§7 註）

## 11. 風險與已知限制

- fullnode `queryEvents` 輪詢有延遲（秒級），demo 時事件流非即時推送 — 可接受
- cap 查詢以 StructType 字串過濾，package id 變更（重部署）要同步 config
- 前端 monotonic 驗證與合約規則重複實作 — 接受（UX 必要），以合約為準
