# Murmur

Murmur captures voice messages from LINE Desktop chats and turns them into transcripts, summaries, sentiment insights, and suggested replies.

## 語音辨識（Task 1 驗證結果）

- **採用 API**：macOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber`（`zh-TW` 在 `supportedLocale(equivalentTo:)` 中可用，語系資源缺少時透過 `AssetInventory` 下載）；不支援時才退回 `SFSpeechRecognizer`。辨識結果再經 `Hant.convert`（Hans-Hant）統一為繁體。
- **實測**：`swift run murmur transcribe ~/Downloads/_38494212.m4a`（約 11 分 16 秒、16kHz 單聲道 AAC）輸出 1454 字繁體逐字稿，耗時約 8.8 秒（stderr 印 `transcribe: 8.8s`）。
- **授權方式**：以 `-Xlinker -sectcreate __TEXT __info_plist` 將 `Sources/murmur/Info.plist`（`CFBundleIdentifier` = `com.murmur.cli`、`NSSpeechRecognitionUsageDescription`）嵌入執行檔。`SpeechAnalyzer` 路徑實測不需額外授權提示即可從 CLI 執行；`SFSpeechRecognizer` 後備路徑才會呼叫 `requestAuthorization`。未需要改包 `.app`。
