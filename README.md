# MoMoWhisper

<p align="center">
  <strong>繁體中文</strong> · <a href="README.en.md">English</a>
</p>

MoMoWhisper 是一套開源的會議錄音與逐字稿工作台。macOS 版會將麥克風與系統音訊分流處理、保留會議歷史，並能產生本機摘要或由使用者明確設定的 AI 摘要；另有獨立的 Windows x64 Beta，提供本機雙音源錄音與會後轉錄。

> **發布狀態：**原始碼、未簽章的 Windows x64 Beta，以及採 ad-hoc 簽章的 macOS universal Beta 均已公開。兩個安裝版目前都沒有受信任的發行者簽章；macOS Beta 尚未通過 Apple 公證，首次開啟需要手動允許 Gatekeeper 例外。

## 平台支援

| 平台 | 狀態 |
|---|---|
| macOS 26+ | Beta；優先使用 SpeechAnalyzer 轉錄。 |
| macOS 14–25 | Beta；預設使用 Apple Speech，並能安全回退至此引擎。 |
| Windows 10 1809+ / 11 x64 | Beta；獨立的 .NET 實作，停止錄音後在本機轉錄。 |

目前的安裝包支援 macOS 14 以上版本。SpeechAnalyzer 本身需要 macOS 26；舊版系統無法選用，錄音時會改用 Apple Speech。`arm64` 產物只能在 Apple 晶片 Mac 上執行；`universal` 產物同時包含 `arm64` 與 `x86_64`，可供 Apple 晶片與 Intel Mac 使用。未來正式公證的發布流程強制要求 universal build，任一架構無法產生便會停止發布。

## 主要功能

- 麥克風與系統音訊轉錄模式；要同時進行分流雙音源轉錄，需使用 macOS 26 以上的 SpeechAnalyzer。
- 帶時間戳記及麥克風／系統音訊標籤的逐字稿片段。
- 錄音 session 生命週期保護與多段錄音 metadata。
- 可搜尋的會議歷史、Markdown 匯出及交付就緒檢查。
- Summary V2 閱讀模式：一句話摘要、主題分組、決議／需求／待辦／待確認／風險分類、搜尋與篩選，以及來源與處理覆蓋狀態。
- 長會議預設只顯示每個主題最重要的 8 項；完整稽核內容可由「複製完整重點」取得。已提交會議的權威摘要位於 `session_state_v1.json#/snapshot/summaryDocument`；`summary_document.json` 與預設 Markdown 是方便舊工具與人工閱讀的可變相容預覽，不能取代權威 snapshot。
- 使用者手動編輯並鎖定的重點不會被後續 AI 更新覆寫；逐字稿變更會使舊摘要失效並重新計算。
- 極短會議只有在逐字稿達 300 字，或含人工建立／使用者鎖定的摘要內容時，才可更新 `latest_valid` handoff；純 AI 或純備援摘要不會覆蓋前一份可信交付。
- macOS Codex handoff schema v2 以 `sessionTransactionID` 與 `sessionStatePath` 綁定同一筆 `session_state_v1.json` 提交；就緒檢查會重新讀取權威 envelope，驗證 transaction ID、meeting ID、schema、路徑邊界與 snapshot 結構。缺漏、過期、不一致、路徑越界或無法解碼時會 fail closed，但這不是密碼學式的防竄改簽章。handoff 中的相容預覽路徑不受信任；Windows Beta 使用獨立 handoff schema，沒有這條 macOS transaction trust chain。
- 歷史列表使用權威快照提交後才寫入的輕量 `history_index_v1.json` 與記憶體快取；自動儲存不會為了更新列表而重新解碼所有長會議。
- 一般自動儲存採 250 ms debounce 與同 session latest-wins 合併，由單一背景 writer 串行寫入；已開始的提交不會在中途取消。停止錄音、清除／切換 session 與最終匯出等邊界使用零延遲 flush，避免在 UI／ASR callback 上同步序列化持續增長的逐字稿。
- 已結束會議的人工修正會重新提交 final highlights 與 handoff，讓 `latest_valid` 維持與最新權威 transaction 一致。「下一場」只有在權威 snapshot 與必要附件都成功後才會切換；錄音中不能清空。
- 按下 Cmd-Q 時，App 會暫緩終止並等待最新 revision 與 final artifacts 落盤；若保存或附件輸出失敗，會取消退出並保留目前會議供使用者重試。
- 預設為「僅逐字稿」模式。
- 本機備援摘要、本機 LM Studio、DeepSeek，以及自訂 OpenAI-compatible endpoint。
- API key 儲存於 macOS Keychain。

## 安裝 macOS 未簽署 Beta

1. 開啟本 repository 的 [**Releases**](https://github.com/jordannn02/MoMoWhisper/releases) 頁面。
2. 下載 `MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg` 與 `MoMoWhisper-0.2.0-macOS-universal-unsigned.sha256`。ZIP 是同一份 universal app 的替代格式。
3. 驗證 DMG checksum：

   ```bash
   cd ~/Downloads
   grep 'MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg$' \
     MoMoWhisper-0.2.0-macOS-universal-unsigned.sha256 |
     shasum -a 256 -c -
   ```

4. 開啟 DMG，將 `MoMoWhisper.app` 拖入「應用程式」。
5. 先嘗試開啟一次。Gatekeeper 預期會阻擋這個採 ad-hoc 簽章且未公證的 Beta。
6. 確認 checksum 正確且信任本 repository 後，前往 **系統設定 → 隱私權與安全性**，捲動至「安全性」，對 MoMoWhisper 選擇 **仍要打開**。Apple 的單一 App 例外操作說明見[此處](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac)。
7. 啟動 App 並完成權限導引。

檔名中的 `unsigned` 是刻意保留的信任邊界：此 App 只有 ad-hoc 結構簽章，沒有 Apple Developer Team 身分、沒有公證票證，也沒有 Apple 惡意程式掃描結果。Checksum 只能確認下載內容是否與發布檔一致，不能證明發行者身分或軟體安全性。請勿全域停用 Gatekeeper、執行其他來源的副本，或略過「會損害您的 Mac」或「包含惡意軟體」等警告。未來標示為 `developer-id-notarized` 的版本才是一般正式散佈版，不需要這項手動例外。

## 安裝 Windows Beta

1. 開啟本 repository 的 [**Releases**](https://github.com/jordannn02/MoMoWhisper/releases) 頁面。
2. 下載 `MoMoWhisper-Windows-Beta-<version>-x64-Setup.exe` 與 `MoMoWhisper-Windows-Beta-SHA256SUMS.txt`。
3. 驗證 SHA-256 checksum，再執行每位使用者安裝程式。
4. Windows 詢問時授予麥克風權限；重要會議前，先進行一次簡短的麥克風／系統音訊測試。

Windows 版本明確標示為 **unsigned Beta**。在取得 Authenticode 發行者憑證及更完整的 Windows 10/11 相容性證據前，Microsoft Defender SmartScreen 可能顯示「未知的發行者」。此 Beta 會將麥克風與系統播放錄成不同音軌，停止錄音後再於本機轉錄；目前尚未具備與 macOS 即時轉錄版完全相同的功能。精確限制與資料位置請見 [windows/README.md](windows/README.md)。

Windows 的 `momowhisper.windows-beta.v2` handoff 是獨立格式，不包含 macOS 的 `sessionTransactionID`／`sessionStatePath` transaction 驗證；請勿把 macOS Summary V2 的交付信任宣稱套用到 Windows Beta。

Windows 安裝程式由 GitHub-hosted Windows CI 建立；只有 tag workflow 的核心測試、whisper runtime 靜態檢查、靜默安裝、程式啟動與解除安裝 smoke test 全部成功後，才會附加至 GitHub Release。本機 macOS build/test 不構成 Windows 安裝包已通過驗證的證據。

## 權限

MoMoWhisper 只會依所選模式要求必要權限：

- 「語音辨識」：供 Apple 轉錄使用。
- 「麥克風」：擷取麥克風音訊。
- 「螢幕與系統錄音」：擷取電腦播放音訊。

變更「螢幕與系統錄音」權限後，請完整結束 MoMoWhisper 再重新開啟。

## 資料與隱私預設值

新的 macOS 安裝預設將會議資料存放於本機：

```text
~/Library/Application Support/MoMoWhisper/
```

App 不會在未告知的情況下將資料移至 iCloud。你可以在設定中明確選擇同步資料夾來存放錄音或重點。

Windows Beta 將會議資料存放於本機 `%LOCALAPPDATA%\MoMoWhisper\WindowsBeta\`，不會上傳逐字稿或音訊。兩個平台的保留與加密邊界請見 [PRIVACY.md](PRIVACY.md)。

新安裝預設為 **僅逐字稿**。本機自動摘要不會連線第三方；只有在你明確選擇並設定 DeepSeek、LM Studio 或其他 OpenAI-compatible endpoint 後，逐字稿文字才可能透過網路送出。依 macOS 版本、語言與系統可用性不同，Apple Speech 可能使用 Apple 營運的服務。

錄製敏感會議或啟用遠端摘要供應商前，請先閱讀 [PRIVACY.md](PRIVACY.md)。

## 從原始碼建置

需求：

- macOS 14 以上。
- 目前版本 Xcode 或 Command Line Tools 提供的 Swift 6 toolchain。

建置並執行可重現的 regression runner：

```bash
TMPDIR=/tmp swift build -j 4 --scratch-path /tmp/momowhisper-build
TMPDIR=/tmp swift run -j 4 --scratch-path /tmp/momowhisper-runner MoMoWhisperLifecycleTestRunner
```

建立本機 ad-hoc app bundle 與 DMG：

```bash
MOMO_WHISPER_OUTPUT_DIR=/tmp/momowhisper-dist \
  bash scripts/package-macos.sh
```

驗證 ad-hoc 產物結構：

```bash
bash scripts/verify-macos-release.sh --allow-adhoc \
  /tmp/momowhisper-dist/MoMoWhisper-0.2.0-macOS-arm64-unsigned.dmg
```

Ad-hoc 產物預設不具公開發布就緒狀態，仍標記為 `PublicDistributionReady: no`。0.2.0 Beta 是經擁有者明確同意、清楚標示的 unsigned Beta 例外；自動化 workflow 只建立結構驗證過的 CI 產物，不會自動把 ad-hoc Mac 產物附加到 Release。缺少 notary profile 的 Developer ID build 會標示為 `developer-id-unnotarized`，同樣不具一般散佈就緒狀態。一般公開打包必須具備 Developer ID Application 身分、Apple 公證與 `--universal`；只有 App 與 DMG 都通過公證及 staple 後，script 才會寫入 `developer-id-notarized` 與 `PublicDistributionReady: yes`。詳見 `scripts/package-macos.sh --help`。

## 第一次使用

1. 選擇 Apple Speech；系統支援時也可選 SpeechAnalyzer。
2. 選擇音訊模式與麥克風。
3. 視需求執行會前健康檢查與系統音訊測試。
4. 開始錄音，確認音量與逐字稿片段持續更新。
5. 停止後開啟 Delivery Center，檢查逐字稿、摘要、錄音分段與 handoff 就緒狀態。

## 摘要供應商

- **僅逐字稿**：預設模式，不會連線任何摘要 endpoint。
- **本機自動摘要**：僅使用本機備援。
- **LM Studio**：必須在設定中明確輸入 endpoint；本機使用建議設定為 localhost。
- **DeepSeek／其他 OpenAI-compatible API**：必須在設定中明確儲存 endpoint、model 與 API key。

遠端摘要請求只包含已提交的逐字稿片段、近期文字脈絡，以及既有摘要目錄中需要延續判斷的 headline、主題 ID／標題／別名，與項目 ID／所屬主題／類型／狀態／文字／負責人／期限／手動鎖定狀態；不會傳送原始音訊。供應商失敗時，本機備援會保留每個失敗範圍，介面也會分開顯示 AI、本機備援、待處理與待重試覆蓋。

MoMoWhisper 不會從環境變數、下載項目或舊版 handoff 檔案載入 API token。

## 開發驗證

```bash
TMPDIR=/tmp swift test -j 4 --scratch-path /tmp/momowhisper-tests
TMPDIR=/tmp swift run -j 4 --scratch-path /tmp/momowhisper-runner MoMoWhisperLifecycleTestRunner
bash scripts/run-summary-v2-smoke-tests.sh
```

漏洞回報方式請見 [SECURITY.md](SECURITY.md)，相依套件邊界請見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 授權

MoMoWhisper 採用 MIT License，詳見 [LICENSE](LICENSE)。
