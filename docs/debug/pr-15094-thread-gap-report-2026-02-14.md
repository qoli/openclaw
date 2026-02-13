# PR #15094 驗證報告：Telegram DM Thread 與 DM History Limit 脫鉤

日期：2026-02-14  
分支：`test/pr-15094-token-optimization`  
目標 PR：`openclaw/openclaw#15094`

## 1. 摘要結論

本次驗證確認：

1. `DM history limit` 功能存在且可運作，但只對 `sessionKey kind = direct/dm` 生效。
2. Telegram DM thread 路徑實際使用 `...:thread:<id>` 形態的 key，因此不會命中 `DM history limit`。
3. 對於 thread-heavy 使用方式，本 PR 的 token 優化效果會被明顯稀釋，體感接近「沒變」。

## 2. 問題陳述

使用者在 Telegram DM thread 場景觀察到：

- 狀態列仍顯示 `Context: 16k/262k`。
- 合併 PR #15094 後，未感受到預期的 token 降幅。

## 3. 程式層證據

### 3.1 DM history limit 僅接受 `direct/dm`

`src/agents/pi-embedded-runner/history.ts` 中：

- `getDmHistoryLimitFromSessionKey` 解析 `kind` 後，僅允許 `direct` 或 `dm`。
- 其他值（例如 `thread`）直接 `return undefined`，等於不套用限制。

關鍵位置：`src/agents/pi-embedded-runner/history.ts:45-50`

### 3.2 Telegram DM thread 會生成 thread key

`src/telegram/bot-message-context.ts` 中：

- DM thread 使用 `resolveThreadSessionKeys`，session key 會加上 `:thread:<id>`。

關鍵位置：`src/telegram/bot-message-context.ts:176-186`

### 3.3 實際 session key 驗證

當前會話（本次測試）：

- `sessionKey = agent:main:main:thread:389429`

該 key 在 `getDmHistoryLimitFromSessionKey` 中被解析為：

- `provider = main`
- `kind = thread`

結論：不命中 DM history limit。

### 3.4 DM history limit 套用點

DM history limit 會在送模型前執行：

- `src/agents/pi-embedded-runner/run/attempt.ts:588-591`
- `src/agents/pi-embedded-runner/compact.ts:434-437`

但前提是 `getDmHistoryLimitFromSessionKey(...)` 有回傳數值。

## 4. 歷史脈絡（功能來源）

`DM history limit` 並非 PR #15094 新功能，早在 2026-01-11 已引入：

- `a005a97fe` feat: add configurable DM history limit
- `54abf4b0d` feat: add per-DM history limit overrides
- `a4385dc92` fix: skip dm history limit for non-dm sessions

PR #15094 主要對此邏輯的影響是：

- 在 provider config 不存在時 fallback 預設 `50`（仍受 `kind` 篩選約束）。

## 5. 實測觀察

### 5.1 為何看起來一直是 `16k`

UI 的 token 顯示會做簡寫：

- `formatTokenCount` 對 `>= 10,000` 以整數 `k` 顯示。
- 因此 `15.6k`、`16.4k` 都可能顯示成 `16k`。

關鍵位置：`src/utils/usage-format.ts:19-27`

### 5.2 本次 thread 的近期數值（同 topic）

近期兩筆相鄰 session 的 input token：

- `16798 -> 16634`（下降 `164`）

代表優化不是完全無效，但在此路徑下幅度有限，且容易被 UI 簡寫掩蓋。

## 6. 影響評估

對象：

- 使用 Telegram DM thread（或其他 thread/session suffix）作為主要互動模式的使用者。

影響：

1. 長對話 token 累積不受 `dmHistoryLimit` 控制。
2. 成本、延遲與上下文膨脹風險高於預期。
3. PR #15094 的效益主要落在 metadata/skills 等子項，無法解決 thread 路徑的核心歷史累積問題。

## 7. 建議（本報告僅建議，未實作）

1. `getDmHistoryLimitFromSessionKey` 應支援 thread/topic 子會話回推父 key 判斷（parent direct/dm 時套用）。
2. 或在 DM thread 建 key 時保留 provider/direct 語義（避免 `provider=main, kind=thread` 無法辨識來源 provider）。
3. 狀態列可增加精確 token（例如同時顯示 `16634`），降低「已優化但看不出」的觀測落差。

## 8. 最終結論

本次問題不是「DM history limit 功能壞掉」，而是「thread 化 session key 未被該功能設計納入」，屬於路徑覆蓋缺口。  
因此你的判斷「thread 一直被遺忘」在目前程式行為上成立。
