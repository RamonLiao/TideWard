# RiskGuard — Move Implementation Notes

> 一個 chat 一個 module。本檔記錄每個 module 的目的、鏈上限制、測試結果、已知風險。

## 2026-05-30 — `admin.move` (control plane: genesis + market registration)

### 目的
RiskGuard 的 AdminCap-gated 控制面。兩個職責：(1) `init` genesis 在 publish 時 mint 唯一 root `AdminCap` 給 deployer；(2) `register_market<M>` 是 market 上線的**唯一**路徑——內建建 oracle → policy<M> → 3 caps → share，無外部 object-id 入參。這一輪同時把前兩輪掛著的 `#[allow(unused_function)]` 全清掉（wiring 補齊）。

### 交付檔案
- `sources/admin.move`（新）— `init`、`register_market<M>`、`init_for_testing`
- `sources/oracle.move` — +`public(package) share_oracle`（無-store seam）；`new_oracle` 移 allow
- `sources/events.move` — +`MarketRegistered{market, policy_id, oracle_id, ts_ms}` + emitter
- `sources/caps.move` / `sources/policy.move` — 移除全部 5 處 `#[allow(unused_function)]`
- `tests/admin_tests.move` — 6 tests（用 test_scenario，總 **30 passed / 0 warnings**）

### 設計重點 / 鏈上限制
- **無-store share seam**：`RiskOracle has key`（無 `store`）→ `transfer::share_object` 只能在定義 module 呼叫。所以 admin **不能**直接 share oracle，必須走 `oracle::share_oracle`。`RiskPolicy<M> has key,store` → admin 可直接 `public_share_object`。
- **無外部 id 入參防 misbind**：oracle 在函式內現建，`object::id(&oracle)` 在 share 前讀（id 跨 share 穩定），policy + 3 caps 全綁同一個 fresh oracle_id。caller 無法把 cap 指向錯誤 oracle。
- **1 market = 1 oracle + 1 policy<M>**：oracle 帶單一 `nonce`/`latest_score`，跨 market 共用會混 replay guard，故維持 1:1。
- **cap 三向分發**（threat-model 角色分離）：publisher→KMS 位址、stop→on-call 熱錢包、override→per-market DAO multisig（顯式三 address 參數，使用者拍板）。
- **admin.move 零 error const**：所有 invariant delegate 給 `policy::new`（EBadConfig/EInvalidBps）與 `oracle::new_oracle`（EBadConfig），不重複 assert → 避免 §2.6 error code 漂移。

### 紅隊覆蓋（核心 auth，5 向量）
1. 未授權註冊 → `&AdminCap` possession，type system 強制（無 runtime test，沒 cap 編譯不過）
2. cap misbind 錯 oracle → oracle 內建、無外部 id 入參 ✓
3. double-share → 物件現建只 share 一次 ✓
4. object-id 不穩 → share 前讀 `object::id` ✓
5. genesis AdminCap 被竊 → `init` 發給 deployer（須為 ops multisig，**deployment-time invariant，標 known**）

### dual-review 結果（2026-05-30，兩輪制）
- **Round 1 內部（move-code-quality）** — PASS。param order objects-first ✓、`public` 非 entry ✓、`MarketRegistered` 過去式 ✓、method syntax ✓、doc 完整 ✓。
- **Round 2 外部（codex exec）** — 2 findings：
  - **F1 Medium（已修）**：`policy::new` 沒驗 `max_conf_bps <= MAX_BPS`。constructor 驗了 ltv/min_loosen 卻漏 conf → fat-finger（如 60000）讓 oracle 的 `conf_bps <= max_conf_bps` 形同虛設。加 `assert!(max_conf_bps <= MAX_BPS, EInvalidBps)` + 測試 `register_with_excessive_max_conf_aborts`（abort 20）。
  - **F2 Low/Med（by-design，已加 doc）**：同 `M` 可重複註冊。**不修**——A1 = off-chain registry 為 source of truth，A2 已刻意砍中央 shared object；在 admin 加 on-chain uniqueness registry = 重新引入被砍掉的競爭點 = overengineering。attacker 無 AdminCap，重複註冊只能是 ops 失誤 → off-chain「latest wins」。`register_market` doc 標 KNOWN LIMITATION，丟 architecture P1 backlog。
  - codex 確認：cap misbind / auth bypass / atomicity / id 穩定性 **無 finding**。
- **Verdict: Ship as-is**（pending 獨立 `sui-security-guard` + `sui-red-team` 全鏈路審計）。

### 測試結果
`sui move test` → **30 passed / 0 failed / 0 warnings**（policy 11 + oracle 14 + admin 6 - 1... 實際 policy/oracle 共 24 + admin 6 = 30）。admin 6：genesis 單 cap、分發+share+1 event、bad-config atomic rollback、excessive-conf abort、雙 market 隔離。

### 已知限制 / 待辦
- 重複註冊同 `M` 無 on-chain 防護（見 F2，by-design）→ architecture P1 評估是否要 on-chain uniqueness。
- `pyth_adapter` 仍未實作 → 下個 chat 接真 Pyth（testnet BUCK/USD §9.5，Option 2→1 純 append）。
- **完整 `sui-security-guard` + `sui-red-team` skill 仍未獨立跑**（本輪 inline 紅隊 + move-code-quality + codex）→ 全 module wiring 已齊，建議下個 chat 跑 post→apply→register 全鏈路。

### 下一個 module
`pyth_adapter.move`（接真 Pyth；Option 2→1 純 append、`post_score_and_apply` ABI 不變）。或先獨立跑完整 security-guard + red-team。

---

## 2026-05-30 — `oracle.move` (+ caps 補 3 caps, events 改 pause 事件)

### 目的
RiskGuard 的鏈上寫入入口。`RiskOracle`（type-erased shared，無 phantom）存 latest score / replay nonce / `active` kill switch。`post_score_and_apply<M>` 是 off-chain executor 唯一寫路徑：驗 publisher cap + freshness/conf + replay → 委派 `policy::apply_decision`。DAG：`oracle → policy`，policy 不反向依賴。

### 交付檔案
- `sources/oracle.move` — `RiskOracle`, `PriceReading`（Pyth seam）, `post_score_and_apply`, `pause_oracle`(EmergencyStopCap) / `resume_oracle`(AdminCap), read helpers
- `sources/caps.move` — 補 `AdminCap` / `RiskOraclePublisherCap{oracle_id}` / `EmergencyStopCap{oracle_id}` + 3 minters + 2 accessors
- `sources/events.move` — `PolicyPaused{market}` → `OraclePaused`/`OracleResumed`{oracle, by, ts_ms}
- `tests/oracle_tests.move` — 12 tests，全綠（總 23 passed / 0 warnings）

### Pyth seam（GTM 決策，2026-05-30 確認）
- 採 **Option 2**：oracle 吃自家 `PriceReading{conf_bps, publish_ts_ms}`，**不**吃 `pyth::PriceInfoObject`。
- `new_price_reading` 是 `public(package)` → 唯一能造 production reading 的是未來同 package 的 `pyth_adapter`（讀真 Pyth object）。型別本身即信任邊界（threat #4 teeth）。
- 升 production（Option 1）= **純 append**：加 `pyth_adapter` module + Move.toml 加 Wormhole/Pyth deps + 砍 test_only minter。**`post_score_and_apply` ABI 不變**（spec §10(6)：Pyth update 走 upstream PTB step）。
- ⚠️ 關鍵紀律：簽名鎖在自家 `PriceReading` 型別，不可改吃 `PriceInfoObject`（否則 ABI break 全部 executor PTB）。

### 規格偏離（已確認）
1. **param order**：move-code-quality §5「objects first」→ `post_score_and_apply(oracle, policy, cap, ...)`、`pause_oracle(oracle, cap, ...)`、`resume_oracle(oracle, admin, ...)`，與 spec §2.4 cap-first 不同（對齊 policy::revert_action）。
2. **`PolicyPaused{market}` → `OraclePaused`/`OracleResumed`{oracle}**：pause 是 oracle-scoped、entry 無 M，market-keying 錯誤。拆 on/off 兩事件。
3. **錯誤碼純 u64 無 `#[error]`**：延續 policy.move 慣例（off-chain 把數字當契約 + 跨 module expected_failure）。
4. **`PriceReading` 取代 spec 的 `pyth_price_obj: &PriceInfoObject` 參數**（見 Pyth seam）。

### 紅隊覆蓋（apply 路徑 5 向量，全有 test）
1. Replay（nonce 非遞增）→ EReplay=7 ✓ `replay_same_nonce_rejected`
2. Stale price → EStaleOracle=6 ✓ `stale_reading_rejected` + 邊界 `staleness_edge_accepted` + 未來時間 `future_dated_reading_rejected`
3. Wide confidence（低流動性 depeg 放鬆）→ EConfTooWide=10 ✓ `wide_confidence_rejected`
4. Cap/policy 綁錯 oracle（double-bind）→ EWrongOracle=12 ✓ `cap_for_wrong_oracle_rejected` + `policy_bound_to_wrong_oracle_rejected` + `stop_cap_for_wrong_oracle_rejected`
5. Paused 時 post（kill switch bypass）→ EOraclePaused=14 ✓ `paused_post_rejected`

### 測試結果
`sui move test` → **25 passed / 0 failed / 0 warnings**（policy 11 + oracle 14）。
含 2 個跨模組整合（monkey）測試：B3 cooldown（#13）與 MAX_PENDING（#11）經 oracle 寫路徑觸發 policy guard。

### dual-review 結果（2026-05-30）
- **Round 1 (codex)** — codex CLI 起初 hang（無 git repo + stdin 未關）；修正 `--skip-git-repo-check < /dev/null` 後成功。3 findings：
  - **F1 Medium（已修）**：freshness `publish_ts + max_staleness` 可 u64 overflow → 改減法 `now - publish_ts <= max_staleness`（前置 assert 保證不 underflow）。
  - **F2 High（by-design，已加 doc）**：`resume_oracle` 收任何 `AdminCap`、未綁 oracle。確認為 spec §2.7/B2 全域 root 設計（2-of-3 multisig，stop 綁 oracle / resume 全域）。非 code bug，已在 fn doc 標 accepted centralization。
  - **F3 Medium（已修）**：`PriceReading` 的 `public(package)` 構造子 package-wide 可達 → 砍掉無 caller 的 production `new_price_reading`，只留 `#[test_only]` minter。non-test build 無法構造 `PriceReading`，直到 `pyth_adapter` 加驗證構造子。struct doc 標 TRUST INVARIANT。
  - codex 確認：無 replay bypass、cap/policy double-bind 正確。
- **Round 2 (專案規則)** — 無 must-fix。`test.md` Monkey Testing 缺口 → 補上述 2 整合測試。
- **Verdict: Ship as-is**（pending 獨立 `sui-security-guard` + `sui-red-team` 全鏈路審計）。

### 已知限制 / 待辦
- `pyth_adapter` 未實作（Option 2 stub）→ 下個 chat 接真 Pyth（testnet BUCK/USD feed 已確認 §9.5）。
- `admin.move` 未寫：`new_oracle` / cap minters 目前 `public(package)` + `#[allow(unused_function)]`，等 admin chat 加 AdminCap-gated public entry + share oracle。
- **完整 `sui-security-guard` + `sui-red-team` skill 尚未跑**（本輪 inline 紅隊 + move-code-quality）→ 獨立 chat 跑 post→apply 全鏈路。
- `oracle.move` read helpers（latest_score_* 等）目前無 caller，待 frontend/executor preflight 接。

### 下一個 module
`pyth_adapter.move`（接真 Pyth）或 `admin.move`（market registration + cap 發放 + share）。建議先 `admin.move` 把 wiring 補齊（移除 `#[allow(unused_function)]`），再 Pyth。

---

## 2026-05-30 — `policy.move` (+ leaf: events, caps)

### 目的
RiskGuard 核心 gate。`RiskPolicy<phantom M>` shared object，存當前風控立場（LTV cap + per-action pause flags）+ revert 所需最小狀態（`pending_actions` snapshots，上限 8）。

### 交付檔案
- `sources/policy.move` — RiskPolicy<M>, ActionSnapshot, Decision, 4× `assert_*_allowed` gates, read helpers, `apply_decision`, `revert_action`
- `sources/events.move` — 4 event structs + `public(package)` emit fns
- `sources/caps.move` — `OverrideCap<M>` only（其餘 4 caps 待 admin/oracle chat 補）
- `tests/policy_tests.move` — 11 tests, 全綠

### 規格偏離（已確認，需回寫 spec）
1. **`post_score_and_apply` 不在 policy.move**（spec §2.4 原放這）。它吃 `&mut RiskOracle` + `RiskOraclePublisherCap` → 會造成 `policy → oracle` 反向依賴破壞 DAG。改：policy 暴露 `public(package) apply_decision`，由下個 chat 的 `oracle::post_score_and_apply` 驗 cap/active/nonce/staleness/conf 後呼叫。`apply_decision` 只管 policy 狀態變更（snapshot + B3 rate limit + MAX_PENDING gate + 寫值 + emit）。
2. **砍 `errors.move`**：Move `const` 無法跨 module import（沒有 `public const`）。錯誤碼改各 module 本地定義。policy 的錯誤碼 EPascalCase 命名、純 u64、值對齊 spec §2.6（不用 `#[error]`，因 off-chain 把數字當契約 + 跨 module test `expected_failure` 拿不到私有常數）。
3. **`revert_action` 參數順序**：object（policy）在 cap 前（move-code-quality §5），與 spec §2.4 cap-first 不同。
4. **`revert_action` 多收 `ctx: &TxContext`**：為了 `ActionReverted.by` 事件記 sender。spec 簽名無 ctx。

### 設計重點
- **Cascading revert**：revert action N → 還原 N 的 pre-image + `pop_back` 到 N（後續 action 的 prev_* 都建在 N 效果上，全砍 = N 及其後沒發生）。
- **B3 非對稱 rate limit**：`is_loosening`（升 LTV **或** 清任一保護 flag，用 `prev & (new ^ 0xFF)` 算被清旗標）→ 吃冷卻；緊縮免冷卻；revert 不重置 `last_loosen_ts_ms`。
- **`prune_expired`**：append 序保證 front 最舊，從前砍到第一個未過期。
- **gates 保留 `_clock` 參數**：目前未用，為 ABI 穩定（v1 要接 oracle freshness）+ lender 本來就 thread clock。

### 紅隊 finding（已修）
- **Vector 5**：`min_loosen_interval_ms = 0` 會關掉 B3 節流。constructor 原本只檢 `< revert_window`，已加 `> 0` guard（`EBadConfig`）+ 測試 `zero_cooldown_rejected`。

### 測試結果
`sui move test` → 11 passed / 0 failed / 0 warnings。涵蓋：tighten+read、LTV/pause gates、loosen 冷卻前拒後過、cascade revert、revert 窗外拒、wrong-policy spoof 拒、MAX_PENDING、prune、zero-cooldown 拒。

### 環境
- sui CLI **1.71.0**（spec target testnet 1.72.2）。`type_name::get` → 改 `with_defining_ids`。Move.toml 砍掉 explicit Sui dep 改 implicit（CLI bundled framework，部署時用 testnet-matching CLI 對齊 Protocol 124）。

### 已知限制 / 待辦
- 4 個 cap（AdminCap / PublisherCap / EmergencyStopCap）尚未定義 → oracle/admin chat 補進 caps.move。
- `apply_decision` / `new` / `new_override_cap` 目前 `#[allow(unused_function)]`（等 oracle/admin chat wire 起來後移除）。
- **完整 `sui-security-guard` + `sui-red-team` skill 尚未跑**（本輪只做 inline 紅隊自審）→ 建議獨立 chat 跑，尤其 oracle 寫完後對 post→apply 全鏈路。

### 下一個 module
`oracle.move`：RiskOracle（active flag / nonce / staleness / max_conf）、`post_score_and_apply`（驗證後呼叫 `policy::apply_decision`）、`pause_oracle`(EmergencyStopCap) / `resume_oracle`(AdminCap)。順手解 P1-B5 Switchboard stub 決策。

---

## 全鏈路 Security Audit + 紅隊（2026-05-30）

範圍：`register_market → post_score_and_apply → apply_decision/revert_action`。跑 `sui-security-guard`（secret 掃描乾淨）+ `sui-red-team`（5 模組靜態對抗 + 5 向量）。

### 結論：0 EXPLOITED。5 向量全 DEFENDED
- Access-control：全 construct/mint = `public(package)`；5 public 突變點各自 cap-gated；`apply_decision` 僅 oracle 可呼叫。
- Replay：`nonce > oracle.nonce` 嚴格遞增（per-oracle）。
- Double-bind：cap→oracle ∧ policy→oracle 雙綁；`M` 由 policy 型別推導，無法跨市場混用。
- Economic：B3 非對稱節流；revert 不重置冷卻。
- DoS：MAX_PENDING gate + prune；staleness 減法防溢位。

### 已修硬化（patch + 測試）
- **H1**：`revert_action`(:262) 與 `prune_expired`(:301) 由 `ts + window` 改 `now - ts <= window`，防 admin 把 `revert_window_ms` 設到近 u64::MAX 時溢位 abort（與 oracle.move staleness 一致）。測試 `huge_revert_window_no_overflow`。
- **H2**：`new_decision` 加 `new_flags & ~KNOWN_FLAGS == 0`（`EInvalidFlags=22`），拒未定義 flag bit 寫入 policy。測試 `undefined_flag_bit_rejected`。

### 設計層級觀察（by-design，未改，記錄供決策）
- **O1**：MAX_PENDING 飽和會連帶擋掉「收緊」路徑（gate 在分類 loosen/tighten 前）。被入侵 publisher 可用 no-op 填滿 → 擋安全方向一個 revert_window。前提 key 洩漏，對策 EmergencyStop。硬化選項：apply_decision 對 no-op early-return（省 storage、ABI 微變）→ 丟 P2。
- **O2**：revert = OverrideCap 持有者不受節流的 loosen（刻意：人工凌駕 > 機器節流，限窗內）。保留。
- **O3**：同 M 重複註冊無鏈上 uniqueness（codex F2 已知，latest-wins，無跨市場污染）。保留，P1 backlog。

### 取證
`sui move test` → **32 passed / 0 failed / 0 warnings**（+2：H1/H2）。`sui move build` 0 warning。secret 掃描 0 命中。`.gitignore` 補 `.env*`/`*.key`/`*.pem`/`build/`。

Confidence ~70%（5 向量系統性 + 組合推理；未跑新增 fuzzing round，既有 32 tests 已鎖所有 abort 路徑）。

---

## 2026-05-31 — `pyth_adapter.move`（Pyth seam Option 2→1，已實作）

### 目的
新增 `pyth_adapter.move` = 唯一 production `oracle::PriceReading` 鑄造路徑，解碼真實 Pyth `PriceInfoObject` 並綁定 per-market expected feed id。關閉威脅 #4（偽造 freshness datum）：持有 production `PriceReading` = 證明來自*綁定 feed* 的已驗 Pyth read。

### 修改的 module
- **Move.toml**：加 Pyth（`rev="sui-contract-testnet"`）+ Wormhole（`rev="sui/testnet"`）git deps。CLI 1.71 下框架自動管理，**無 framework 衝突**（plan 的 `override=true` fallback 未動用）。
- **oracle.move**：`RiskOracle` 加 `expected_feed_id: vector<u8>` 欄位；`new_oracle` 加 param + 收緊 assert（`max_staleness_ms >= 1000`、feed id 必 32 bytes）；加 `expected_feed_id()` getter；加 production `public(package) new_price_reading`（取代「無 production 構造子」的 F3 過渡狀態）；test minter 改 delegate。
- **admin.move**：`register_market<M>` 加 `expected_feed_id` param，threaded 進 `new_oracle`（AdminCap-gated、deploy-time config）。
- **pyth_adapter.move（新）**：`read_price`（薄 PriceInfoObject 解碼 wrapper）+ `compute_reading`（純 primitive 核心）。Pyth API 全對著**實際下載 source**（commit `62c7a5b`）核對：`get_price_no_older_than` / `price_info::get_price_info_from_price_info_object` / `get_price_identifier` / `price_identifier::get_bytes` / `price::get_price|get_conf|get_timestamp` / `i64::get_is_negative|get_magnitude_if_positive`。

### Rule 7 衝突修正（更正先前「純 append」說法）
舊 notes 稱 Option 2→1 = 純 append。**只對一半**：`post_score_and_apply` 外部 ABI 不變，但本次**加了 `RiskOracle` struct 欄位** + `new_oracle`/`register_market` 多 param（storage + signature 變更）。刻意接受：per-oracle feed config 是安全多市場 production 必需。

### 🔴 升級相容鐵律（sui-architect C1）
加 `expected_feed_id` 改 struct layout。SUI Move 升級檢查**禁止對既有 struct 加欄位**。現在免費 = package 未 publish（`Move.toml`=0x0）。**mainnet 上線後 `RiskOracle` 不得再加任何欄位**；之後 per-oracle config 一律走 dynamic field / companion object。

### 偏離 plan
- plan 簽名 `read_price<M>`，`M` body 完全未用（RiskOracle type-erased）→ 觸發 W09010。為 0-warning **移除 `<M>`** → `read_price(oracle, pio, clock)`，功能等價。

### 測試
- `compute_reading`：純 primitive 完整單測（happy / EWrongFeed / EInvalidPrice×2 / conf 飽和 / 2× monkey / 1× red-team truncated-feed）。
- ⚠️ **`read_price` 的 PriceInfoObject 解碼無 on-chain 單測**（Pyth 無 public test constructor，`new_price_info_object` = `public(friend)`）。**刻意 gap** → off-chain PTB 整合測試（`SuiPythClient.updatePriceFeeds`，獨立 TS 任務）覆蓋。**不得宣稱全覆蓋**（Rule 12）。

### Review（SUI chain）
- **move-code-quality**：1 處修正（test attr 合併 `#[test, expected_failure]` 對齊慣例）；error const plain-u64 為已記錄之刻意偏離。
- **sui-security-guard**：0 secret 命中；`.gitignore` 仍覆蓋。
- **sui-red-team**（6 向量，trust-boundary）：**0 EXPLOITED**。feed 替換(bytes/長度)→EWrongFeed；stale→Pyth 內部 abort(delegated)；conf 爆→u128+飽和；neg/zero→EInvalidPrice；無 cap 偽造 reading→PriceReading 無 store + new_price_reading public(package) + post_score_and_apply 仍要 cap。

### 取證
`sui move test` → **41 passed / 0 failed / 0 warnings**（32 → +1 bad_feed_id +7 adapter +1 red-team）。`sui move build` 0 warning（僅上游 Pyth doc-comment，非本專案）。

### ⚠️ 待辦（mainnet 前）
- `rev` 是 branch 非 commit hash → **mainnet 前 pin commit**。
- off-chain TS：`read_price` PTB 整合測試（① updatePriceFeeds → ② read_price → ③ post_score_and_apply）。
- `register_market` 傳真實 feed id：testnet BUCK/USD `0xed08...aabf` / mainnet `0xfdf2...7382`（spec §9.5）。

---

## 2026-06-01 — off-chain TS PTB 整合測試完成（read_price decode gap 關閉）✅
- **目的**：`read_price` 對真實 `PriceInfoObject` 的解碼鏈上測不到 → 用 testnet live e2e 全鏈路覆蓋。
- **部署（testnet，env key = CLI active address）**：
  - package `0xc91fb4f514c82af209ae459308f56cda33dc99406f288dd1a97da8731b8b4003`
  - adminCap `0xff1864ec…d947` / oracle `0x04e70d51…dba5` / policy `0xbada3065…4882` / publisherCap `0xd9ca6572…ea3a`
  - 記於 `ts/.deployed.json`（gitignored）。market type = `0x2::sui::SUI`（phantom marker，零 Move 改動）。
- **CLI build / framework 對齊**：`sui 1.71.0` + `sui move build` 過（Pyth/Wormhole git deps，override fallback 未動用，僅上游 doc-comment warning）→ blocker #2 解除。
- **測試結果（`pnpm test e2e`，live testnet）**：
  - ✅ positive：updatePriceFeeds → read_price → new_decision → post_score_and_apply 全鏈路成功；ScorePosted.score_bps=7777 / nonce、ActionExecuted.new_ltv=4000；鏈上 `latest_score_bps=7777` 落地。
  - ✅ EReplay：non-increasing nonce → `post_score_and_apply` abort code **7** 確認。
  - ⏭️ staleness：default skip（read_price 比 post_score 嚴，EStaleOracle=6 不可達；真測需 1s-window oracle + `STALE_ORACLE_ID`，spec §8）。
- **踩雷（非合約 bug）**：
  1. `findCreated` 對 generic struct（`RiskPolicy<M>`）`.endsWith` 失敗 → 補 `.includes(suffix+"<")`。register tx 其實已上鏈成功，只是 parse id 炸（副作用已發生）。
  2. positive 讀 `latest_score_bps=0` = fullnode read-after-write 舊版本 → 加 `waitForTransaction` 再讀。
  3. EReplay 測：SDK 估 gas 的 dry-run 對必 abort tx 直接 throw（到不了 status failure）→ `tx.setGasBudget(1e8)` 跳過 dry-run，才拿到上鏈 failure。
  4. `pnpm deploy/register` 是 pnpm 保留字 → 用 `pnpm run deploy/register`。
- **取證**：e2e 2 passed / 1 skipped；TSC 綠。
- **⚠️ mainnet 前**：pin `rev` commit hash；`register_market` 傳真實 feed id（testnet BUCK/USD `0xed08…aabf`）；本次 e2e 用 SUI/USD testnet `0x50c6…a266`。

---

## 2026-06-04 — `upgrade_registry.move` 實作完成（C4 §2.8，72h timelock upgrade）✅
- **目的**：把 package `UpgradeCap` 包進 shared `UpgradeRegistry`，所有升級走 72h timelock + permissionless execute/commit + 全事件透明。raw cap 永不外露。
- **執行方式**：subagent-driven-development，7 tasks 全 TDD（每 task red→green）。
- **新增**：1 module `sources/upgrade_registry.move`（5 fn + 4 read helper）+ `events.move` append 3 events/emitters。零碰其他 module。
- **5 fn**（param order 已對齊 codebase objects-first 慣例）：
  - `init_upgrade_registry(cap: UpgradeCap, _: &AdminCap, ctx)` — one-shot bootstrap，cap moved-in 不可重跑，share registry。
  - `propose_upgrade(reg, _: &AdminCap, digest, policy, clock)` — AdminCap-gated，起 72h timer，guard `EUpgradePending`(40) + `EPolicyTooPermissive`(43, fail-fast 比 cap 現有 policy 更寬即拒)。
  - `cancel_upgrade(reg, _: &AdminCap, ctx)` — AdminCap-gated，epoch++（防 indexer 把 cancel 跟 re-propose 混淆），guard `ENoPending`(41)。
  - `execute_upgrade(reg, clock): UpgradeTicket` — **permissionless**（防 RiskGuard squat pending），guard `ENoPending` + `ETimelockActive`(42)，**不清 pending**（reverted 可重試）。
  - `commit_upgrade(reg, receipt: UpgradeReceipt)` — permissionless，consume hot-potato receipt，bump cap version，清 pending。
- **error codes**：40-43，沿用 plain-u64 慣例（無 `#[error]`，與全 package 一致，deliberate）。`TIMELOCK_MS = 259_200_000`(72h) hardcode 無 setter（v1 才 meta-timelock）。
- **🔑 hot-potato 閉環**：`UpgradeTicket`/`UpgradeReceipt` 皆無 `drop` → `execute → Upgrade → commit` 型別系統強制同一 PTB 原子完成，不存在「execute 跑了 commit 沒跑」的已提交態。
- **🔑 gap 已關（不同於 pyth read_price）**：framework `package::test_publish(id,ctx):UpgradeCap` + `test_upgrade(ticket):UpgradeReceipt` 皆 `test_only` → 全生命週期可鏈上單測。`full_lifecycle_bumps_version_and_clears_pending` 直接斷言 cap version 1→2 + pending 清空。
- **framework API 核實**（build deps source）：`authorize_upgrade(&mut cap,u8,vector<u8>):UpgradeTicket` / `commit_upgrade(&mut cap,UpgradeReceipt)` / `upgrade_policy(&cap):u8` / `version(&cap):u64` / `compatible_policy():u8` / `only_additive_upgrades(&mut cap)`。policy 序：COMPATIBLE=0 < ADDITIVE=128 < DEP_ONLY=192（低=寬）→ `policy >= upgrade_policy(cap)` 拒過寬正確。
- **三輪 review（強制 SUI 鏈）**：
  - `move-code-quality`：修 **param order**（propose/cancel/init 原本 cap-first，改 objects-first 對齊 oracle.move:189,204）+ `..` unpack syntax；plain-u64 errors 為已記錄 deliberate 偏離保留。
  - `sui-security-guard`：合約 0 issue。access-control 全 5 entry 過（UpgradeCap 鎖在 shared registry，`cap` field private，無 fn 回傳 cap 或 &mut；registry key-only 不可 wrap/transfer）。**⚠️ 非合約發現：`.claude/settings.local.json:41` 有明文 testnet privkey**（permission allowlist 捕獲，無 git 故未入歷史，testnet ~19 SUI，建議刪該 entry 改 `export SUI_TESTNET_KEY=*` 並輪換）。
  - `sui-red-team`：5 向量 **全 DEFENDED**。(1)execute before timelock→ETimelockActive (2)re-propose→EUpgradePending (3)無 AdminCap→型別系統強制（call 編不出來）(4)empty registry→ENoPending (5)u64 under/overflow：propose 的 `now+timelock` overflow→arithmetic abort fail-safe；execute 的 `now-proposed` underflow 由 `assert!(now>=proposed)` 擋。**關鍵認知**：Sui Clock 協議單調（`set_for_testing` 都 assert 不可倒退）→ underflow 鏈上不可達，該 assert 是 belt-and-suspenders（測時需第二個低 clock 物件才測得到）。
- **取證**：總 **50 passed / 0 failed**（baseline 41 + upgrade 9：init1/propose3/cancel2/execute2/lifecycle1），0 new warning（僅上游 Pyth doc-comment）。
- **plan 偏離**：plan 寫 `let _ = package::test_upgrade(ticket)` 編不過（UpgradeReceipt 無 drop）→ 改 `std::unit_test::destroy(...)`（unreachable 收尾用，非 deprecated 的 sui::test_utils）。
- **residual risk**：① digest 在 propose 時無法驗（Move 看不到未來 bytecode），execute 時 `authorize_upgrade` 才驗 → propose 階段信任 AdminCap holder 給對 digest。② 無 on-chain cancel 速率限制（AdminCap holder 可反覆 propose/cancel，但無資金面影響）。③ mainnet UpgradeCap 3-of-5 custody 屬合約外運維範疇。

---

## 2026-06-05 — `override.move` 實作完成（DAO 主動保護凌駕）✅
- **目的**：補既有 `revert_action`（撤銷）缺的「主動」路徑 → DAO 用既有 `OverrideCap<M>` 直接 force-tighten LTV / force-pause，繞過 oracle 與 B3 節流，但**只准更保護**（monotonic）。撤銷+主動成完整 DAO 工具組。
- **🔑 關鍵發現（push back）**：原 architecture spec 把 `override.move = "OverrideCap + revert flow"`，但該職責**已實作**（OverrideCap 在 caps.move、revert_action 在 policy.move）→ 照原 spec 開檔是重複工。改為「主動保護凌駕」才是真新能力。
- **執行方式**：brainstorming → spec（sui-architect review）→ writing-plans → subagent-driven 5 tasks（TDD per task + 每 task spec-compliance review）。
- **新增**：1 module `sources/override.move`（1 fn `force_protect`）+ `policy.move` append `apply_override`(public(package)) + `KIND_OVERRIDE=3` + `events.move` append `OverrideApplied`。零碰 oracle/admin/caps/upgrade_registry/pyth_adapter。
- **責任切分（sui-architect M1）**：`force_protect`(override.move) 擁有 override **語意**（cap 綁定 + monotonic + no-op，用 policy public getter 讀）；`apply_override`(policy.move) 擁有**儲存機制**（flag-mask + prune + MAX_PENDING + snapshot + 寫 + emit）。避免退化 wrapper —— 對照 oracle→apply_decision 模式。
- **monotonic-protective 設計**：`new_ltv <= cur_ltv` 且 `cur_flags & new_flags == cur_flags`（只 set bit、不准 clear）。= OverrideCap 被盜的 blast-radius 上限：最多過度收緊（可 revert 回復），永不能 loosen 放行壞借貸。**無 B3 節流**（只收緊故安全）。
- **error codes**：`ENotProtective=23` / `EOverrideNoop=24` 宣告在 **override.move**（使用處，非 spec §2.4 原寫的 policy.move）→ 避免 policy.move unused-const warning。`EWrongPolicy=1001`/`EInvalidFlags=22`/`ETooManyPending=11` 重用。沿用 plain-u64 慣例。
- **可被 revert**：override 共用 `pending_actions` snapshot stack（kind=KIND_OVERRIDE）→ `revert_action` 零新 code 即可在 window 內撤銷（DAO panic-tighten 可自收）。`override_then_revert` 整合測試斷言全 state 還原。
- **L1**：`OverrideApplied` event 帶 `reason_code`（indexer 稽核 why 免讀物件）。
- **三輪 review（強制 SUI 鏈）**：
  - `move-code-quality`：全項通過，零修正（module label / objects-first param / method syntax / `///` / merged test attrs 全合規）。
  - `sui-security-guard`：4 改動檔 secret scan NONE；無新 cap mint、無 public_transfer、`apply_override` 為 public(package) 不外露。
  - `sui-red-team`：5 新向量（unit test 已覆蓋 spec §3.2 五向量外的）**全 DEFENDED**：(1)flag-swap 偽裝→ENotProtective (2)MAX_U16 loosen→ENotProtective (3)ltv=0 極限→安全無 underflow可revert (4)pending flood→ETooManyPending 對特權者亦成立 (5)flood 後 prune 回收→無永久 DoS。0 EXPLOITED。
- **取證**：總 **60 passed / 0 failed**（baseline 50 + override 10：tighten/set_flag/combined 3 happy + loosen/clear_flag/noop/wrong_cap/reserved_flag/pending_full 6 reject + override_then_revert 1 整合），0 new warning（僅上游 Pyth doc-comment）。
- **刻意 tradeoff（known）**：① MAX_PENDING 滿時 force_protect **abort 不繞過**（anti-griefing 一致性；OverrideCap 是 multisig 非 griefing 源；prune/revert 可恢復，紅隊 3b 驗無永久 DoS）。② override 本身可被 revert（刻意，DAO 可收回自己 panic）。
- **module 名**：`riskguard::override` —— `override` 非 Move 保留字，build 通過。

---

## 2026-06-20 — 前端 DAO 操作台（`app/`）+ off-chain 部署/整合（`ts/`）✅
> 非 Move 任務，但與合約 ABI / 鏈上資料形狀強耦合，記在此檔便於合約改動時連帶檢視。

### 交付
- `ts/`（@mysten/sui 2.17，node 24 / pnpm 11）— 部署/維運 scripts：`deploy`(⚠️`pnpm run deploy`，`deploy` 是 pnpm 保留字) / `register` / `init-registry` / `gen-env`。id 寫 `ts/.deployed.json`（gitignored）。
- `app/`（React 19.2 / Vite 8 / TS 6，@mysten/dapp-kit-react 2.0.3）— DAO 操作台：Markets / Upgrades / Docs 分頁 + 連錢包 cap-gated 操作（pause/resume、force_protect/revert、upgrade propose/cancel + 72h 倒數）+ event ticker 跑馬燈。

### `ts/.deployed.json` schema（9 keys，gen-env 來源）
`packageId` / `adminCapId` / `oracleId` / `policyId` / `publisherCapId` / `upgradeCapId` / `emergencyCapId` / `overrideCapId` / `upgradeRegistryId`。
- `gen-env` 只把 5 個進 `app/.env.local`：`PKG / ORACLE / POLICY / REGISTRY / RPC`。**cap id 刻意不進 env** → 前端即時讀「連線錢包 owned caps」做 gating（每種 cap 鏈上僅 1 owned object，誰持有誰能操作）。
- ⚠️ `deploy.ts` 寫檔是 **merge**（首跑會殘留舊 oracle/policy）→ `register` 覆蓋為新 ids 才正確（已用 EventTicker `MarketRegistered` 對齊驗證）。

### SDK 分工 / transport 決策
- **官方 forward path = gRPC `client.core.*` 為 default**；deprecated JSON-RPC 只保留在「無 gRPC 等價物」的最小範圍（事件歷史 `queryEvents`），隔離單檔 + 註明退場條件（見 2026-06-12 lesson）。
- gRPC `core.getObject` 要 `include:{json:true}` 讀 `res.object.json`（**不是** `content:true→.content.fields`，後者是 BCS bytes 會碎）。
- `useCaps` 列全部 owned 再 client-side `resolveCaps` 過濾（避開 gRPC 對 generic `OverrideCap<M>` 的 type-filter 前綴匹配風險）。
- 失敗交易 `JSON.stringify(result.FailedTransaction)` 餵 `explainTxError` 抽 MoveAbort code，不賭巢狀 `.status.error.message`。

### 🐛 本次抓修 2 個 live-only bug（皆 transport-shape 坑，單測 fixture 餵理想形全綠抓不到）
1. **address-form（咬 2 次，`bafda16`）**：config 用短寫 `0x2::sui::SUI`，但鏈上 `OverrideCap<M>` 的 type filter 是 full-padded 64-hex、event 的 TypeName 更是 full-padded **且無 0x 前綴** → FORCE PROTECT 鈕永遠 disabled、MARKET EVENTS 漏顯示 OverrideApplied。修：抽 `overrideCapIdFor`(caps.ts，過 `normalizeStructTag`) + `eventMatchesMarket`(parsers.ts，額外比對 no-0x 形) 純函式 + regression test 鎖短/長/無-0x 三型。
2. **digest base64（`c520c80`）**：gRPC json 把 Move `vector<u8>` digest 序列化成 **base64 字串**，`parseRegistry` 卻 cast `as number[]` → propose 一上鏈，UpgradesPage `pending.digest.map()` 瞬間 `TypeError: digest.map is not a function` 整頁白屏。修：抽 `toBytes()` 容忍 array / base64 / 0x-hex 三型 + 2 regression test 鎖 base64 與 hex 形。

### 鐵律（呼應 `.claude/rules/test.md` 的 live/monkey testing）
凡是「鏈上讀進來的值」，單測 fixture **必須複刻真實 transport 序列化形**（u64=string、`vector<u8>`=base64、TypeName=full-padded-no-0x），不能餵理想形 — 否則全綠的測試對 live bug 零防護（三度踩雷）。

### live 驗證取證（testnet，2026-06-20，全 cap 歸 demo 錢包 `0xbdecf8a2…3ee01f`）
- 讀取路徑：Markets SUI/USD 5000bps/SCORE0/PENDING0/ACTIVE、cap gating disabled、0 console errors。
- 寫入路徑（鏈上 events 為證）：OraclePaused/Resumed、OverrideApplied #0 reason7 5000→4000 + #1/#2 4000→3000 各自 ActionReverted、upgrade propose→PENDING(epoch0)+`71h56m`倒數→cancel epoch 0→1。
- **35 vitest 全綠、`tsc -b` 綠、Playwright 0 console errors**。兩輪 review（`bafda16` diff）verdict: ship as-is。

### 已知 / 未驗
- ⬜ **monkey testing**（極端輸入/連點/拒簽/斷網）寫入路徑需在真錢包瀏覽器手動操作（Playwright 那顆無錢包擴充）— 唯一剩餘 TODO。
- demo 操作模型（合約決定）：每種 cap 鏈上僅 1 owned object → 多人無法同時操作同一 cap → 走「共用 demo 操作員錢包」(deploy 自動持全 cap，助記詞給評審 import)。**故 deploy 用可分享 demo 錢包，非主錢包**。
