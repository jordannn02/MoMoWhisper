# MoMoWhisper 0.2.0 Beta

繁體中文｜[English](#english)

這次 Beta 的核心升級是 macOS **Summary V2**：把難讀、重複且容易被截斷的會議重點，改成可搜尋、可篩選、可追溯的結構化閱讀介面。Windows 安裝包沿用既有 0.1 功能範圍，本次沒有宣稱與 macOS Summary V2 同步。

## macOS：Summary V2

- 一句話摘要與主題分組，並區分決議、需求、待辦、待確認、風險、事實與備註。
- 長主題預設顯示最高優先的 8 項；完整稽核可由「複製完整重點」取得。已提交會議的權威摘要為 `session_state_v1.json#/snapshot/summaryDocument`；`summary_document.json` 與預設 Markdown 是可變相容預覽，不是交易事實來源。
- 支援全文搜尋、類型篩選、分範圍複製、證據節錄、負責人／期限與手動鎖定。
- 摘要供應商改傳增量操作；App 端負責驗證、去重、合併、解決與取代，避免 AI 每輪重寫整份摘要。
- 手動鎖定內容不會被 AI 覆寫；逐字稿編輯或 ASR 前綴變更會立即使舊 AI／備援覆蓋失效並重新計算。
- DeepSeek、LM Studio 或自訂 endpoint 失敗時，備援摘要保留每個失敗文字範圍，並分開顯示 AI、備援、待處理與待重試覆蓋。
- Summary V2、逐字稿與重試狀態以同一份 `session_state_v1.json` 權威 snapshot 提交，並在載入或送出網路重試前驗證一致性。
- macOS Codex handoff 升級為 schema v2，透過 `sessionTransactionID` 與 `sessionStatePath` 綁定權威提交。readiness 會重新讀取 envelope，驗證 transaction ID、meeting ID、schema、路徑邊界與 snapshot 結構；缺漏、舊交易、不一致、路徑越界或無法解碼皆 fail closed。這不是密碼學式防竄改簽章；Windows Beta 也沒有這條 macOS transaction trust chain。
- `latest_valid` handoff 採 fail-closed：逐字稿未達 300 字時，只有人工建立或使用者鎖定的摘要內容可更新；純 AI／純備援摘要不會覆蓋前一份可信交付。
- 歷史列表改讀權威 snapshot 提交後才產生的輕量索引，badge 使用記憶體快取；自動儲存直接更新當前紀錄，不再逐句重掃並解碼全部長會議。
- 一般自動儲存採 250 ms debounce、同 session latest-wins 合併與單一背景 writer；已開始的原子提交不中途取消。停止、清除／切換 session 與最終匯出等邊界使用零延遲 flush，避免識別 callback 因完整逐字稿序列化而停頓。
- 已結束會議的人工修正會重發 final highlights／handoff，維持 `latest_valid` 與最新權威 transaction 的一致性；「下一場」只在 snapshot 與必要附件成功後切換，錄音中不可清空。
- Cmd-Q 會以 AppKit `terminateLater` 等待最新 revision 與 final artifacts 落盤；失敗時取消退出並保留當前 session 供重試。

## macOS 安裝與信任邊界

- 下載 `MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg`；ZIP 是同一 universal app 的替代格式。
- 支援 macOS 14+，同時包含 Apple silicon (`arm64`) 與 Intel (`x86_64`)。
- 這是採 ad-hoc 結構簽章、**未使用 Developer ID、未經 Apple 公證**的 Beta。Gatekeeper 預期會阻擋；請先驗證隨附 SHA-256，再依 README 的單一 App「仍要打開」流程處理。
- 請勿全域停用 Gatekeeper，也不要略過「會損害您的 Mac」或惡意軟體警告。

## Windows x64 Beta

- 仍提供 WASAPI 麥克風／系統播放分軌錄音、本機 whisper.cpp 會後轉錄、逐字稿與 handoff 產物。
- Windows 安裝程式由 GitHub-hosted Windows CI 建立；只有 tag workflow 成功完成核心測試、靜態 whisper runtime 驗證、靜默安裝、程式啟動與解除安裝 smoke test 後，才會附加到 GitHub Release。本機 macOS 驗證不等於 Windows 安裝包已通過這些檢查。
- 安裝程式仍是 **unsigned Beta**；SmartScreen 可能顯示未知發行者。

## 隱私

- 新安裝預設為僅逐字稿，不會自動連線摘要供應商。
- 遠端摘要只在使用者明確設定後，傳送已提交的逐字稿片段、近期文字脈絡，以及 headline、主題 ID／標題／別名、項目 ID／所屬主題／類型／狀態／文字／負責人／期限／手動鎖定狀態；不傳送原始音訊。
- 詳細資料位置、保留與第三方 endpoint 邊界請見 `PRIVACY.md`。

---

## English

The main change in this Beta is **Summary V2** for macOS. Dense, repetitive, or truncated meeting bullets are replaced by a structured reading surface that is searchable, filterable, and traceable. The Windows installer retains its existing 0.1 feature scope; this release does not claim macOS Summary V2 parity on Windows.

### macOS: Summary V2

- Headline and topic groups with decisions, requirements, actions, open questions, risks, facts, and notes.
- Long topics show the eight highest-priority items by default, while Copy Full Summary exposes the complete audit. For a committed meeting, the authoritative summary is `session_state_v1.json#/snapshot/summaryDocument`; `summary_document.json` and default Markdown are mutable compatibility previews, not transaction facts.
- Full-text search, type filters, scoped copy, evidence excerpts, owner/due-date fields, and user locks.
- Providers return validated delta operations instead of rewriting the full summary on every pass.
- User-locked content survives AI updates; transcript edits or ASR prefix changes invalidate stale generated coverage and trigger recomputation.
- Every failed provider range is preserved by local fallback, with separate AI, fallback, pending, and retry coverage.
- Summary V2, transcript, and retry state are committed in one authoritative `session_state_v1.json` snapshot and validated before loading or sending a retry request.
- macOS Codex handoff schema v2 binds the handoff to that commit with `sessionTransactionID` and `sessionStatePath`. Readiness re-reads the envelope and verifies its transaction ID, meeting ID, schema, path boundary, and snapshot structure; missing data, stale transactions, mismatches, path escapes, or undecodable evidence fail closed. This is not a cryptographic anti-tamper signature, and the Windows Beta does not implement this macOS transaction chain.
- The `latest_valid` handoff is fail-closed: below 300 transcript characters, only manual or user-locked summary content can update it; AI-only and fallback-only summaries cannot replace the previous trusted handoff.
- Meeting history reads a lightweight post-commit index and renders trust badges from memory. Autosave updates the current record directly instead of rescanning and decoding every long meeting after each utterance.
- Routine autosaves use a 250 ms debounce, same-session latest-wins coalescing, and one serialized background writer. Started atomic commits are not cancelled midway; stop, clear/session-switch, and final-export boundaries use a zero-delay flush so recognition callbacks do not synchronously serialize the complete growing transcript.
- Manual edits to ended meetings republish final highlights/handoff artifacts, keeping `latest_valid` bound to the newest authoritative transaction. Next Meeting switches only after the snapshot and required artifacts succeed; Clear is blocked during recording.
- Cmd-Q uses AppKit `terminateLater` to wait for the newest revision and final artifacts. A failure cancels termination and keeps the current session available for retry.

### macOS installation and trust boundary

- Download `MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg`; the ZIP contains the same universal app.
- Supports macOS 14+ on Apple silicon (`arm64`) and Intel (`x86_64`).
- This is an ad-hoc structurally signed Beta with **no Developer ID identity and no Apple notarization**. Gatekeeper is expected to block it. Verify the published SHA-256 first, then follow the per-app Open Anyway flow in the README.
- Do not disable Gatekeeper globally or bypass a malware/damage warning.

### Windows x64 Beta

- Retains WASAPI microphone/system-playback recording, local post-stop whisper.cpp transcription, transcript artifacts, and handoff output.
- The installer is built by GitHub-hosted Windows CI and is attached to the GitHub Release only after the tag workflow completes core tests, static whisper runtime checks, silent install, executable smoke mode, and uninstall verification. Local macOS verification does not establish that the Windows installer passed those checks.
- The installer remains an **unsigned Beta**, so SmartScreen may show an unknown publisher.

### Privacy

- New installs default to transcript only and do not contact a summary provider automatically.
- A remote provider receives committed transcript excerpts, recent text context, and the existing headline, topic ID/title/aliases, and item ID/topic/type/status/text/owner/due-date/manual-lock fields only after explicit configuration; raw audio is not sent.
- See `PRIVACY.md` for storage, retention, and endpoint boundaries.
