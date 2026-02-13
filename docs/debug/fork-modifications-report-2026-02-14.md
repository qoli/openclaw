# OpenClaw Fork 修改報告（2026-02-14）

## 1. 範圍與基準

- 比對基準：`upstream/main` → `main`
- 分支狀態：`main` 相對 `upstream/main` 為 `ahead 14 / behind 0`
- 變更統計：`26 files changed, 1733 insertions(+), 240 deletions(-)`

## 2. 主要改動摘要

1. Agent 工具鏈上下文優化（核心）

- 新增 `toolContext=ephemeral` 模式，將舊工具輪次壓縮為摘要，減少主呼叫上下文膨脹。
- 摘要子呼叫明確禁用 tools（`tools: []` + `toolChoice: "none"`）。
- 新增批次摘要與上限控制，避免每輪都額外打一次摘要呼叫。
- 預設觸發門檻調整為 4 輪。

2. 可觀測性強化（針對本次問題）

- 新增 summary 成功資訊 log（壓縮輪數、剩餘 message 數）。
- 新增獨立稽核日誌：`/tmp/openclaw/ephemeral-summary-YYYY-MM-DD.log`，不依賴主 logger。
- 新增監看腳本：`watch-openclaw-log-tailspin.sh`，同時觀察 LM Studio 請求量與 summary 狀態。

3. Doctor / Config 相容性修復

- Doctor 流程允許 `agents.defaults.contextPruning.toolContext`，避免誤判 config 無效。
- 補上對應測試，確保 `toolContext` 設定在 doctor 流程可通過。

4. 文檔與流程輔助

- 新增 context 膨脹調查報告。
- 更新 `AGENTS.md`（含測試環境配置路徑說明）。
- 新增 Debian via SSH 建置腳本，並整合 gateway restart + doctor fix。

5. 其他功能性改動

- agents/model/tool 相容性相關調整（包含 web search / model compat）。
- browser 預執行腳本功能曾新增後回退（先實驗、後移除）。

## 3. 提交清單（upstream/main..main）

1. `ecd4fa53d` feat(agents): 模型工具支援檢查與 DuckDuckGo 搜尋
2. `d5b4970a1` feat(browser): 瀏覽器啟動前預先執行腳本
3. `808215445` refactor(browser): 移除瀏覽器預先執行腳本
4. `9580d809f` docs(AGENTS): 重寫 AGENTS.md（fork 工作流）
5. `01ebfd646` docs(project): 移除符號連結文件
6. `3faa2c0bb` docs(debug): context message 膨脹調查報告
7. `1dd0192b7` docs(AGENTS): 測試環境配置路徑說明
8. `c23fd2a8b` feat(doctor): 配置驗證問題分組與向前相容
9. `be18e7b16` feat(agent-runner): 工具上下文臨時壓縮
10. `6af597321` build(scripts): Debian SSH 建置腳本
11. `e9f9a4770` feat(tool-context-ephemeral): 批次摘要與摘要呼叫上限
12. `339809455` chore(build): 遠端部署腳本加入重啟與檢查
13. `39fa5cd04` feat(tool-context-ephemeral): 暫存工具摘要稽核
14. `9a519b8a1` feat(scripts): 監控日誌腳本

## 4. 核心技術結果（針對 Context 膨脹）

- 從 LM Studio 記錄可觀察到 `conversation with 2 messages` 的子呼叫，對應摘要分身呼叫。
- 主呼叫 message 數仍可能偏高，主因是「保留最近輪次」仍含大型 toolResult（例如 browser snapshot）。
- 現行設計已具備壓縮能力，但最終 token 成本仍受「最近輪次 payload 體積」影響。

## 5. 影響檔案（重點）

- `src/agents/pi-embedded-runner/run/tool-context-ephemeral.ts`
- `src/agents/pi-embedded-runner/run/tool-context-ephemeral.test.ts`
- `src/agents/pi-embedded-runner/run/attempt.ts`
- `src/agents/transcript-policy.ts`
- `src/config/zod-schema.agent-defaults.ts`
- `src/config/types.agent-defaults.ts`
- `src/commands/doctor-config-flow.ts`
- `src/commands/doctor-config-flow.test.ts`
- `build-debian-via-ssh.sh`
- `watch-openclaw-log-tailspin.sh`
- `docs/debug/context-message-bloat-investigation-2026-02-13.md`
- `AGENTS.md`

## 6. 風險與後續建議

1. 風險：大型 toolResult 仍可能造成主呼叫上下文偏大。
2. 建議：對保留輪次中的 toolResult 增加大小上限或結構化截斷策略。
3. 建議：將 summary 稽核 log 納入固定觀測面板，避免僅依賴主 logger。
4. 建議：針對長工具鏈場景追加 e2e 壓測，驗證 token 增長曲線。
