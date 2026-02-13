# Context Messages 膨脹調查報告（2026-02-13）

## 目標

針對以下假設做確認：

`tool call` 的執行是否被歸在主對話 session 下，並造成 `context messages` 膨脹。

## 調查範圍

- 代碼路徑：`src/agents/**`、`src/auto-reply/**`、`src/gateway/**`、`src/routing/**`
- 驗證方式：閱讀實作 + 跑最小測試集（工具事件、session transcript、dispatch 分流）
- 日期：2026-02-13

## 核心結論

結論：**成立**。目前預設行為下，tool 執行與結果會進入同一主對話 transcript，並透過多條事件通道輸出；在 DM + tool-events 客戶端 + queue collect 條件下，膨脹體感最明顯。

## 主要發現

1. Tool 執行與主對話共用同一 session transcript
- `SessionManager.open(params.sessionFile)` 直接以主 session file 開啟：`src/agents/pi-embedded-runner/run/attempt.ts:433`
- run 完成後取 `activeSession.messages` 快照，代表工具交互也在同一訊息流：`src/agents/pi-embedded-runner/run/attempt.ts:869`
- `appendMessage` guard 會攔截並持久化 toolResult 到 transcript：`src/agents/session-tool-result-guard.ts:138`、`src/agents/session-tool-result-guard.ts:189`、`src/agents/session-tool-result-guard.ts:223`

2. toolResult 會進入後續模型上下文（非僅 UI 事件）
- `sanitizeSessionHistory` 只移除 `toolResult.details`，保留 `toolResult` 本體：`src/agents/pi-embedded-runner/google.ts:464`
- 測試明確驗證只 strip `details`：`src/agents/pi-embedded-runner/sanitize-session-history.tool-result-details.test.ts:7`

3. Tool 事件會持續發送（start/update/result）
- 事件流固定 emit `stream: "tool"` 三個 phase：`src/agents/pi-embedded-subscribe.handlers.tools.ts:95`、`src/agents/pi-embedded-subscribe.handlers.tools.ts:152`、`src/agents/pi-embedded-subscribe.handlers.tools.ts:220`
- 若開啟 output（full），同一條路徑還會送工具輸出摘要：`src/agents/pi-embedded-subscribe.handlers.tools.ts:247`

4. DM 會發 tool summaries，group 預設不發
- 條件為 `ctx.ChatType !== "group" && ctx.CommandSource !== "native"`：`src/auto-reply/reply/dispatch-from-config.ts:295`
- 成立時注入 `onToolResult` 並送出：`src/auto-reply/reply/dispatch-from-config.ts:301`
- 測試驗證 DM 有、group 無：`src/auto-reply/reply/dispatch-from-config.test.ts:140`、`src/auto-reply/reply/dispatch-from-config.test.ts:167`

5. WebSocket `tool-events` 是另一條高可見輸出通道
- 註解與實作都表明：對註冊 recipients，tool events 會廣播，不受 `verbose=off` 阻止（僅細節裁切）：`src/gateway/server-chat.ts:356`、`src/gateway/server-chat.ts:360`
- `verbose=off` 仍廣播，但不走 node/channel 發送：`src/gateway/server-chat.ts:374`
- 測試驗證此行為：`src/gateway/server-chat.agent-events.test.ts:87`

6. queue 預設 `collect` 會把多訊息拼成單輪 prompt
- 預設 queue mode 是 `collect`：`src/auto-reply/reply/queue/settings.ts:8`
- collect 會組合 `[Queued messages while agent was busy]` 大 prompt：`src/auto-reply/reply/queue/drain.ts:86`
- 這會進一步放大單輪上下文負載（與 tool messages 疊加）

7. 預設 DM session key 常落到 `agent:main:main`
- 沒有特別設定 `dmScope` 時，direct 會回退到 main session key：`src/routing/session-key.ts:178`
- 測試也驗證 default route 為 `agent:main:main`：`src/routing/resolve-route.test.ts:17`

## 已有保護機制與限制

- 有 toolResult 持久化截斷，但硬上限仍高（`400000` chars）：`src/agents/pi-embedded-runner/tool-result-truncation.ts:19`
- 也有 overflow 後的補救截斷流程，但屬於錯誤恢復而非前置控制：`src/agents/pi-embedded-runner/run.ts:566`

## 實測驗證

執行命令（使用本機暫時安裝的 pnpm）：

```bash
CI=true PATH=/tmp/pnpm-local/bin:$PATH PNPM_HOME=/tmp/pnpm-home XDG_CACHE_HOME=/tmp/.cache XDG_DATA_HOME=/tmp/.local/share XDG_STATE_HOME=/tmp/.local/state pnpm exec vitest run src/auto-reply/reply/dispatch-from-config.test.ts src/auto-reply/reply/queue.collect-routing.test.ts src/agents/session-tool-result-guard.test.ts src/agents/session-tool-result-guard.tool-result-persist-hook.test.ts src/agents/pi-embedded-runner/sanitize-session-history.tool-result-details.test.ts src/agents/pi-embedded-runner.sanitize-session-history.test.ts src/agents/pi-embedded-subscribe.subscribe-embedded-pi-session.waits-multiple-compaction-retries-before-resolving.test.ts src/gateway/server-chat.agent-events.test.ts src/gateway/ws-log.test.ts
```

結果：

- Test Files: `9 passed`
- Tests: `58 passed`

## 風險評估

- 功能正確性風險：低（測試覆蓋的行為與設計一致）
- 上下文膨脹風險：中到高（取決於工具輸出大小、DM verbose、WS tool-events、queue collect）
- 可觀測性噪音風險：中（UI 若訂閱 tool-events，會看到大量 tool phase 訊息）

## 建議（僅報告，不含本次修改）

1. 配置層快速降噪
- DM 預設 `verboseLevel: "off"`，避免 tool summary/output 對外送出
- 對長對話 DM 啟用更嚴格 history turn 限制
- 將 queue mode 從 `collect` 改為 `steer` 或降低 `debounceMs`

2. 產品層分流
- 增加選項：DM 可關閉 `onToolResult`（目前由 chat type + command source 決定）
- 增加選項：WS `tool-events` 在 `verbose=off` 時可完全停發（非僅裁切 payload）

3. 持久化層瘦身
- 將 toolResult persistence 上限從 400k 下調到更保守區間（例如 20k 到 50k）
- 引入「工具結果摘要持久化」模式，原文僅保留 hash/metadata

## 備註

- 本報告僅記錄現況與驗證結果，未修改執行邏輯。
