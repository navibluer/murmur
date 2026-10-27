# Murmur

把 LINE 語音訊息轉傳給 Murmur bot，幾十秒內就會收到三則回覆：

1. 🎙️【逐字稿】：潤飾過的逐字稿，最上方標示內容分類
2. 🌡️【情緒分析】：說話者的情緒、實際訴求，以及需要留意的施壓或不合理要求
3. 🪄【回覆建議】：3 則可直接傳送的回覆，每則都標上策略，例如【簡短收到】【設立界線】【延後處理】

每則分析也會存進 CSV，方便日後回顧。

整個服務跑在自己的 Mac 上：語音用 macOS 內建的語音辨識轉文字，分析用自己的 Claude API key，音檔處理完就刪除，不會上傳到其他地方。

## 運作方式

```
LINE（轉傳語音）
  → ngrok（公開 HTTPS 網址）
  → murmur serve（127.0.0.1:47821）
      1. 驗證 LINE 簽章、檢查白名單
      2. 下載音檔 → macOS SpeechAnalyzer 轉文字（zh-TW）
      3. 同一段語音分析過了 → 直接沿用 CSV 裡的第一筆結果
         沒分析過         → Claude 分析 → 寫入 CSV
      4. 回覆 3 則 LINE 訊息
```

- 收到 webhook 後 50 秒內完成就用 reply 回覆，超過就改成 push 推送（LINE 的 reply token 只有 1 分鐘有效）。
- Claude 偶爾會回傳空白或 placeholder 這類佔位內容，程式會自動重試，最多 3 次。3 次都失敗，或遇到 API 錯誤，就回錯誤訊息並附上逐字稿。
- 只有 `ALLOWED_USER_IDS` 白名單裡的人能使用。其他人傳訊不會有任何回應，也不會花到 Claude 額度。

## 需求

- macOS 26 以上（用到 `SpeechAnalyzer`），Swift 6.2
- [ngrok](https://ngrok.com)：已登入，並有一個固定網域
- LINE 官方帳號，且已啟用 Messaging API
- Claude API key

## 安裝

### 1. 設定 `.env`

```sh
cp .env.example .env
```

| 變數 | 說明 |
|---|---|
| `LINE_CHANNEL_SECRET` | LINE Developers Console → Basic settings |
| `LINE_CHANNEL_ACCESS_TOKEN` | Messaging API 分頁發行的長期 token |
| `ANTHROPIC_API_KEY` | Claude API key |
| `CLAUDE_MODEL` | 預設 `claude-sonnet-5-5` |
| `ANTHROPIC_WORKSPACE_ID` | 選填；API key 沒有綁定 workspace 時才需要 |
| `ALLOWED_USER_IDS` | 允許使用的 LINE userId，多個用逗號分隔 |
| `PORT` | 預設 `47821` |
| `NGROK_URL` | `scripts/murmurctl install` 必填；你的 ngrok 固定網域，例如 `https://xxx.ngrok-free.app` |
| `RECORDS_PATH` | 選填；CSV 路徑，預設 `data/records.csv` |
| `CONTEXT_FILE` | 選填；使用者情境檔路徑，預設 `context.md`（相對於執行目錄，支援 `~`） |
| `SEED_CATEGORIES` | 選填；初始分類，逗號分隔，預設 `家庭生活,健康醫療,金錢財務,工作事業,閒聊問候` |
| `SPEECH_LOCALE` | 選填；語音辨識語系，預設 `zh-TW`（簡轉繁只在 `zh` 開頭的語系套用） |

`.env` 已列在 `.gitignore` 裡，不會被 commit。

### 2. LINE 後台

1. 在 LINE Official Account Manager 建立官方帳號，並啟用 Messaging API。Messaging API channel 要從這裡建立，LINE Developers Console 無法直接建立。
2. 在回應設定中關閉「自動回應訊息」，並開啟 Webhook。
3. 到 LINE Developers Console 取得 Channel secret，並發行 Channel access token，填進 `.env`。

### 3. 啟動背景服務

```sh
scripts/murmurctl install
```

這個指令會建置 release 版，並把 `murmur serve` 和 ngrok 註冊成 launchd 背景服務：登入 macOS 後自動啟動，程式結束時自動重啟。

ngrok 網域請寫在 `.env` 的 `NGROK_URL`（也可用環境變數 `NGROK_URL=https://<你的網域> scripts/murmurctl install` 臨時指定，環境變數優先）；兩者都沒有時 `install` 會報錯並結束。

### 4. 連上 LINE

1. 在 Messaging API 分頁把 Webhook URL 設成 `https://<你的網域>/webhook`，按 Verify，再開啟 Use webhook。
2. 用自己的 LINE 傳任意一則訊息給 bot。log 會印出 `未授權的 userId: Uxxxx…`，可以用 `scripts/murmurctl logs` 查看。
3. 把這個 userId 填進 `.env` 的 `ALLOWED_USER_IDS`，然後執行 `scripts/murmurctl restart`。
4. 轉傳一則語音給 bot，確認有收到回覆。

## 日常操作

```sh
scripts/murmurctl status      # 服務狀態與 health check
scripts/murmurctl logs        # 即時看 log（ngrok / all 可切換，-n 指定行數；Ctrl+C 離開，不影響服務）
scripts/murmurctl restart     # 改完程式碼後重新建置並重啟
scripts/murmurctl stop        # 暫停（下次登入仍會自動啟動）
scripts/murmurctl start       # 暫停後重新啟動
scripts/murmurctl uninstall   # 移除自動啟動
```

log 存在 `~/Library/Logs/murmur/` 底下的 `serve.log` 和 `ngrok.log`。

## 分析紀錄（CSV）

預設存在 `data/records.csv`，`data/` 已列在 `.gitignore` 裡。

| 欄位 | 內容 |
|---|---|
| 時間 | LINE 收到這則訊息的時間，格式 `yyyy-MM-dd HH:mm`（24 小時制） |
| 指紋 | 原始辨識逐字稿的 SHA256 前 16 碼，用來判斷是不是同一段語音 |
| 分類 | 由 Claude 決定 |
| 逐字稿 | 潤飾後的逐字稿 |
| 情緒分析 | |
| 回覆建議 | 每則一行，格式為 `N. 【策略】內容` |

- 檔案是 UTF-8 含 BOM，Excel 可以直接開啟。開頭是 `=` `+` `-` `@` 的欄位會在前面補一個空白，避免被 Excel 當成公式。
- **去重**：同一段語音再轉傳一次時，會直接沿用第一筆紀錄回覆，不再呼叫 Claude。
- **分類**：初始有家庭生活、健康醫療、金錢財務、工作事業、閒聊問候。每次分析都會把目前所有分類交給 Claude，都不適合時由它新開一個分類。
- **容錯**：CSV 有壞掉的列會略過，不影響其他紀錄。讀檔失敗時不會覆寫原檔。
- **舊格式**：舊版的 7 欄 CSV（含「重點整理」欄）會在 `serve` 啟動時自動轉成新格式，原檔備份為 `records.csv.bak`（已有同名檔時改用加上時間戳記的檔名）。

### 補存舊語音

```sh
swift run murmur backfill <LINE 訊息 ID> [<訊息 ID> ...]
```

訊息 ID 可以從 `serve.log` 每行開頭的 `[數字]` 取得。這個指令只寫入 CSV，不會發送 LINE 訊息；已存在的紀錄會自動略過。因為拿不到原本的訊息時間，時間欄會填補存當下的時間，並依參數順序每則遞增 1 分鐘。

## 調整分析內容

通用的分析規則寫在 `Sources/MurmurCore/Analyzer.swift` 的 `systemPrompt`；跟你個人有關的背景放在**情境檔**，不需要改程式碼：

1. 複製範例：`cp context.example.md context.md`
2. 編輯 `context.md`。它已列在 `.gitignore`，不會進 git。
3. 執行 `scripts/murmurctl restart` 生效。

情境檔路徑可以用 `.env` 的 `CONTEXT_FILE` 指定（預設 `context.md`，相對於執行目錄，支援 `~`）。找不到情境檔時不會報錯，`serve` 啟動時會印出一行提示，之後做一般分析。

情境檔的內容會接在 system prompt 後面（標題為【使用者情境】），可以寫：

- **背景情境**：例如說話者通常是誰、雙方是什麼關係。
- **情緒分析**：要包含哪些項目。
- **回覆建議**：撰寫原則、稱呼，以及有哪些策略標籤。
- **名字校正**：語音辨識常把人名聽錯，這裡可以列出常見的錯字，讓 Claude 改回正確的名字。

情境中的規則與一般規則衝突時，以情境為準。

## 開發

```sh
swift build
swift test                             # 全部測試（swift-testing）
swift test --filter RecordStoreTests   # 只跑單一 suite
swift run murmur transcribe <音檔>      # 只做語音辨識
swift run murmur analyze <音檔>         # 語音辨識 + Claude 分析，不讀寫 CSV
swift run murmur serve                 # 在前景執行 webhook 伺服器
```

- `serve` 會讀取目前目錄的 `.env`，並和環境變數合併；同名時以環境變數為準。
- 路由有 `POST /webhook`（驗簽後立即回 200，在背景處理）和 `GET /health`。
- 程式架構見 [CLAUDE.md](CLAUDE.md)。

### 技術筆記

- **語音辨識**：使用 `SpeechAnalyzer` + `SpeechTranscriber`（zh-TW），不支援時改用 `SFSpeechRecognizer`。辨識結果如果以簡體字為主，會轉成繁體。
- **授權**：用 `-sectcreate __TEXT __info_plist` 把 `Sources/murmur/Info.plist` 嵌進執行檔，CLI 和 launchd 背景執行時都能取得語音辨識權限。
- **耗時**：實測一段 11 分鐘的語音，轉文字約 5 秒，Claude 分析約 25～35 秒。
- **背景執行的限制**：launchd 啟動的程式讀不到 `~/Downloads`、`~/Documents` 這類受保護的資料夾。服務本身只用暫存目錄，不受影響。
- **LINE 的 loading 動畫**：只會在手機版 LINE 13.16.0 以上顯示，LINE Desktop 不會顯示。

## 安全性

- ngrok 只轉發 `127.0.0.1:47821`，對外只開放 `/webhook` 和 `/health` 兩個路徑。
- webhook 用 Channel secret 驗證 HMAC-SHA256 簽章，簽章不對就回 401。請求內容上限 1MB。
- 要保管好的機密有：`.env`（Channel secret、access token、API key），以及 ngrok 的 authtoken（存在 `~/Library/Application Support/ngrok/ngrok.yml`）。
