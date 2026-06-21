# Monkey Testing — B 部分（真錢包寫入層）

> A 部分（client validation + gate）已全綠（2026-06-22，見 progress.md）。
> B 部分打**鏈上寫入層**：拒簽 / 斷網 / race / 同 cap 雙分頁 / 回歸 / 繞 client。
> 需用 demo 操作員錢包 `0xbdecf8a2…3ee01f`（持全部 cap）連線。

## 前置

1. 啟 dev server：`cd app && pnpm dev` → http://localhost:5173/
2. Sui Wallet 擴充 import demo 錢包助記詞 → 切 **testnet** → 連線（右上 Connect Wallet）。
3. 連上後確認：右上 EMERGENCY PAUSE 鈕**不再 disabled**、market drawer 的 FORCE PROTECT 鈕 gate 解開（有 cap）。
4. 開 DevTools Console（F12），全程盯 console 是否白屏 / 紅字 error。

---

## B1 — 送單後錢包按「拒絕」

- **操作**：Markets → 點 SUI/USD → FORCE PROTECT 區，LTV 填 `3500`（合法降），reason `1` → 按 FORCE PROTECT → 錢包跳簽名框 → **按 Reject**。
- **預期**：鈕 busy 解除回 `FORCE PROTECT`、表單顯示 reject 錯誤訊息（`explainTxError` 翻譯後）、**非白屏、非卡 EXECUTING…**、console 無 uncaught。
- **貼回**：錯誤訊息文字 + 「鈕是否恢復可按」。

## B2 — 送單後狂連點（race / double-submit）

- **操作**：LTV 填 `3400` reason `2` → 按 FORCE PROTECT 後**立刻連點 5 下**。
- **預期**：`busy` 鎖住，只送出 1 筆；錢包只跳 1 次簽名。若漏鎖送出第 2 筆 → 第 2 筆鏈上 **abort code 24（no-op）**（因第 1 筆已把 LTV 降到 3400，第 2 筆同值 = no change）。
- **貼回**：錢包跳幾次簽名框 / 鏈上有幾筆 tx / 第 2 筆是否 abort 24。

## B3 — 簽名框開著時斷網

- **操作**：LTV 填 `3300` reason `3` → 按 FORCE PROTECT → 簽名框跳出時**關 wifi** → 按簽名 → 等。再開 wifi → 重試一次。
- **預期**：交易 timeout / network error → 顯示錯誤訊息（非白屏）、鈕恢復可按；開 wifi 後重送成功。
- **貼回**：斷網時的錯誤文字 + 重送是否成功。

## B4 — propose upgrade 上鏈後 Upgrades 倒數無 crash（c520c80 回歸）

> 這是最重要的回歸測試：之前 propose 一上鏈，UpgradesPage `digest.map` 整頁炸（base64 vs number[]），`c520c80` 已修。
- **操作**：Upgrades 頁 → digest 填合法 64 hex（例 `0x` + 64 個 `a`：`0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`）→ policy 選 COMPATIBLE → PROPOSE UPGRADE → 簽名。
- **預期**：上鏈成功後頁面**立即顯示 PENDING + 72h 倒數**（`71h59m…`），digest 正確 render 成 `0xaaaa…`，**無 `digest.map is not a function`、無白屏**。倒數每秒跳動。
- **收尾**：按 CANCEL（AdminCap）撤掉這筆 pending（epoch +1），避免卡 72h timelock。
- **貼回**：是否正常顯示倒數 + digest 顯示對不對 + cancel 是否成功（epoch 變化）。

## B5 — 同 cap 雙分頁同時操作

- **操作**：開兩個瀏覽器分頁都連同一 demo 錢包 → 兩邊都進 SUI/USD FORCE PROTECT → 分頁 A 送 LTV `3200`、**幾乎同時**分頁 B 送 LTV `3100`。
- **預期**：cap 是 owned object，兩筆引用同一 cap version → 後到的那筆鏈上 **object version 衝突 / 被 equivocate**（其中一筆失敗）。驗證不會兩筆都默默成功造成狀態混亂。
- **貼回**：兩筆 tx 結果（哪筆成功哪筆失敗 + 失敗訊息）。

## B6 — console 繞過 client validation 送「升高 LTV」（打鏈上 monotonic 最後防線）

> 證明即使攻擊者繞過前端，鏈上 `force_protect` 的 monotonic 保護仍擋。
- **操作**：DevTools Console 貼以下（把 `<...>` 換成 .env.local / .deployed.json 的值）：
  ```js
  // 直接 build 一筆「升高 LTV 到 9000」的 tx（client 永遠不會放行）
  // 需在 app context 有 SDK；若無法直接取用，改用 ts/ 腳本送同樣 tx
  // 目的：丟給鏈上，斷言 Move abort（升高被拒），而非執行
  ```
  > 簡單法：直接用 `ts/` 寫一個一次性 script 呼叫 `force_protect`，`newLtvBps` 傳 `9000`（> 現值），用 demo 錢包簽。
- **預期**：鏈上 **abort**（override 只准降 LTV，monotonic-protective），LTV **不變**。
- **貼回**：abort code + 鏈上 LTV 是否保持原值。

---

## 判讀後

- 全部如預期 → monkey testing 完成 → 把 `[~]` 改 `[x]`、進 finishing-a-development-branch。
- 任一不如預期 → 貼回，走 systematic-debugging。**特別注意 B1/B3 是否真的 catch 住（非白屏）—— 這是 `useExecute` 的 try/catch 防線**。
