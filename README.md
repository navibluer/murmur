# Murmur

Murmur captures voice messages from LINE Desktop chats and turns them into transcripts, summaries, sentiment insights, and suggested replies.

## 背景常駐（launchd）

`scripts/murmurctl` 把 `murmur serve`（release 版）與 ngrok 註冊成使用者的 LaunchAgent：登入後自動啟動，程式結束會自動重啟。

```sh
scripts/murmurctl install      # 建置 release、安裝並啟動
scripts/murmurctl status       # 執行狀態與 health
scripts/murmurctl logs         # 即時看 serve log（ngrok / all 可切換，-n 指定行數；Ctrl+C 離開不影響服務）
scripts/murmurctl restart      # 改完程式碼後：重新建置並重啟
scripts/murmurctl stop         # 暫停（下次登入仍會啟動）
scripts/murmurctl start        # 暫停後再啟動
scripts/murmurctl uninstall    # 移除自動啟動
```

- log 位置：`~/Library/Logs/murmur/serve.log`、`ngrok.log`。
- ngrok 網域預設為本專案使用的網域，可用 `NGROK_URL=https://… scripts/murmurctl install` 覆寫。
- 背景程式無法讀取 `~/Downloads`、`~/Documents` 等受保護資料夾；服務本身只用暫存目錄，不受影響。

## 語音辨識（Task 1 驗證結果）

- **採用 API**：macOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber`（`zh-TW` 在 `supportedLocale(equivalentTo:)` 中可用，語系資源缺少時透過 `AssetInventory` 下載）；不支援時才退回 `SFSpeechRecognizer`。辨識結果再經 `Hant.convert`（Hans-Hant）處理；注意它只會轉換「以簡體為主」的文字，已是繁體的內容不動。
- **實測**：`swift run murmur transcribe ~/Downloads/_38494212.m4a`（約 11 分 16 秒、16kHz 單聲道 AAC）輸出 1454 字繁體逐字稿。
- **整體耗時（2026-10-22 實測）**：11 分 16 秒測試音檔，轉文字 4.5 秒、Claude 分析 25.5 秒、總計 29.9 秒，低於 50 秒 reply 預算，因此常態走 reply。
- **授權方式**：以 `-Xlinker -sectcreate __TEXT __info_plist` 將 `Sources/murmur/Info.plist`（`CFBundleIdentifier` = `com.murmur.cli`、`NSSpeechRecognitionUsageDescription`）嵌入執行檔。`SpeechAnalyzer` 路徑實測不需額外授權提示即可從 CLI 執行；`SFSpeechRecognizer` 後備路徑才會呼叫 `requestAuthorization`。未需要改包 `.app`。

## 指令

```sh
swift test                      # 全部測試
swift test --filter ServerTests # 單一 suite／測試
swift run murmur transcribe <音檔>  # 只做語音辨識
swift run murmur analyze <音檔>     # 辨識 + Claude 分析（需 ANTHROPIC_API_KEY）
swift run murmur serve              # 啟動 LINE webhook 伺服器（預設 127.0.0.1:47821）
scripts/murmurctl install           # 背景常駐（見上方「背景常駐」）
```

`serve` 會讀取目前目錄的 `.env`（範本見 `.env.example`），並與環境變數合併，環境變數優先。路由：`POST /webhook`（LINE，驗簽後立即回 200，背景處理）、`GET /health`（回 `ok`）。

## LINE 設定

1. 在 LINE Official Account Manager 建立 LINE 官方帳號。
2. 在 Official Account Manager 啟用 Messaging API（channel 由此建立；LINE Developers Console 已無法直接建立 Messaging API channel）。
3. 在 Official Account Manager 的回應設定中，關閉「自動回應訊息」，並開啟 Webhook。
4. 到 LINE Developers Console：Basic settings 取得 Channel secret；Messaging API 分頁發行長期（long-lived）Channel access token。填入 `.env` 的 `LINE_CHANNEL_SECRET`、`LINE_CHANNEL_ACCESS_TOKEN`，並填 `ANTHROPIC_API_KEY`。
5. 啟動伺服器與 ngrok（見下），回 Messaging API 分頁設定 Webhook URL 為 `https://<你的網域>/webhook`，按 Verify，並開啟 Use webhook。
6. 用自己的 LINE 傳任意訊息給 bot；`serve` 的 log 會印出 `未授權的 userId: Uxxxx…`，把該 ID 填入 `.env` 的 `ALLOWED_USER_IDS`（多個以逗號分隔），重啟 `serve`。之後傳語音訊息即可收到逐字稿、摘要、情緒與建議回覆。

## ngrok

LINE 需要公開 HTTPS 網址。安裝並登入 ngrok（`ngrok config add-authtoken <TOKEN>`），再以固定網域轉發本機埠：

```sh
ngrok http 47821 --url https://<你的網域>
```

指令格式依 ngrok 官方 CLI 文件（`ngrok http 8080 --url https://baz.ngrok.dev`）。自選網域名稱是否需付費方案依 ngrok 文件為付費功能；免費帳號可使用自動配發的 dev domain（網域於 ngrok dashboard 的 Domains 頁查看，此步驟未確認）。
