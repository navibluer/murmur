# Murmur LINE Bot — 設計文件

日期：2026-10-22

## 意圖

使用者在 LINE Desktop 收到朋友的語音訊息時，想快速知道「對方說了什麼、重點是什麼、情緒如何、該怎麼回」。做法：把語音**轉傳**給 Murmur LINE bot，bot 在本機 Mac 上轉文字、用 Claude 分析，再把結果回覆到同一個聊天室。LINE bot 就是唯一的操作介面，不做其他 UI。

已確認事實（使用者）：
- LINE 語音訊息可以轉傳給 bot。
- 語音轉文字使用 macOS 內建能力，使用者實測過速度只需數秒。
- 轉傳的語音長度 ≤ 15 分鐘。
- 分析使用使用者的 Claude API credit。

## 目標

1. 收到轉傳語音 → 回覆四項結果：潤飾逐字稿、重點整理、情緒分析、回覆建議。
2. 只服務使用者本人（白名單 userId）。
3. 單一 Swift 執行檔，在使用者的 Mac 上執行。

## 非目標

- 不做網頁、App、Flex Message 卡片（純文字訊息）。
- 不保存歷史紀錄、不做資料庫。
- 不取得原對話脈絡或原發話者（轉傳後 bot 看不到），回覆建議只依語音本身。
- 不部署到雲端（Mac 語音辨識的限制）。

## 反目標（做出來也算失敗的情況）

- 陌生人加好友就能消耗 Claude credit。
- 結果出現簡體中文。
- 長語音時 bot 毫無回應（使用者不知道是否在處理）。
- 音檔或逐字稿殘留在磁碟或進 git。

## 限制與外部事實（已查證 LINE 官方 reference，2026-10-22）

- Webhook 簽章：header `x-line-signature` = Base64(HMAC-SHA256(channel secret, raw body))。
- 音訊事件：`message.type == "audio"`，含 `id`、`duration`（ms，可能缺）、`contentProvider.type`（`line` | `external`）。只有 `line` 能下載。
- 下載：`GET https://api-data.line.me/v2/bot/message/{messageId}/content`，`Authorization: Bearer {channel access token}`。200 = binary（格式見 `Content-Type`）；**202 = 尚在準備**；404 不存在；410 已收回。
- 準備狀態：`GET https://api-data.line.me/v2/bot/message/{messageId}/content/transcoding` → `{ "status": "processing" | "succeeded" | "failed" }`。
- Reply token 僅保證收到 webhook 後 **1 分鐘**內有效，且只能用一次；reply 一次最多 5 則訊息；文字訊息上限 5,000 字。
- Loading 動畫：`POST https://api.line.me/v2/bot/chat/loading/start`，body `{ chatId, loadingSeconds }`，秒數為 5～60 的 5 倍數；只在一對一聊天且使用者正看著畫面時顯示。
- Push message 在免費方案有每月則數上限（額度未確認），僅作為 fallback。
- 本機：macOS 26.5、Swift 6.2.4、arm64；已安裝 ngrok（無 cloudflared）。

## 已決定的做法

### 技術選型（Claude 的決定，使用者同意）
- 全 Swift，Swift Package Manager 專案，單一執行檔 `murmur`。
- HTTP 伺服器：Hummingbird 2。
- 簽章：CryptoKit `HMAC<SHA256>`。
- Claude API：URLSession 直接呼叫 Messages API（無官方 Swift SDK）。
- 語音辨識：優先 `SpeechAnalyzer`/`SpeechTranscriber`（macOS 26），locale `zh-TW`；若不支援 zh-TW 或品質不佳，改用 `SFSpeechRecognizer`（強制 on-device 或允許伺服器皆可，以能跑通為準）。實作時以測試音檔實測後決定，並記錄於 README。
- Tunnel：ngrok（使用者已安裝）。
- 設定：`.env`（`LINE_CHANNEL_SECRET`、`LINE_CHANNEL_ACCESS_TOKEN`、`ANTHROPIC_API_KEY`、`ALLOWED_USER_IDS`（逗號分隔）、`CLAUDE_MODEL`、`PORT`）。`.env` 列入 `.gitignore`，提供 `.env.example`。

### 處理流程
1. `POST /webhook`：驗簽，失敗回 401。驗簽成功**立即回 200**，事件交給背景 Task 處理（避免 LINE 逾時重送）。
2. 對每個事件：
   - 來源 userId 不在白名單 → 忽略（不回覆、不呼叫任何付費 API）。
   - 非 audio 訊息 → reply 一則使用說明（「請轉傳語音訊息給我」）。
   - audio 且 `contentProvider.type == "external"` → reply 說明無法處理。
3. audio 流程：
   1. 呼叫 loading 動畫（60 秒）。
   2. 下載音檔；遇 202 則輪詢 transcoding（間隔約 1 秒，上限約 30 秒），`succeeded` 後再下載，`failed`/逾時則回報錯誤。404/410 回報對應訊息。
   3. 存到暫存目錄，轉文字，**處理完（成功或失敗）都刪除**。
   4. 逐字稿為空 → 回報「沒有辨識到語音內容」。
   5. 呼叫 Claude 分析（見下）。
   6. 回覆結果（見回覆策略）。
4. 時間策略：從收到 webhook 起算，**50 秒內**完成則用 reply token；超過則改用 push（`to` = userId）。錯誤訊息也套用同一策略。

### Claude 分析
- 單次 Messages API 呼叫，system prompt 要求以繁體中文輸出，回傳 JSON：
  - `polished`：潤飾後的逐字稿（修正錯字、補標點、去口語贅詞，不改原意）
  - `summary`：重點整理（條列）
  - `sentiment`：情緒分析（整體情緒、語氣、需要注意的地方）
  - `replies`：2～3 則回覆建議（字串陣列，口吻自然、可直接傳送）
- 模型由 `CLAUDE_MODEL` 指定，預設為 Sonnet 等級最新模型；model id 實作時查官方文件確認，不憑記憶。
- 確保 JSON 可解析：使用 API 的結構化輸出/tool use 能力（實作時依官方文件選擇），解析失敗時回報錯誤而不是丟出原始字串。
- Claude API 失敗（網路、4xx/5xx）→ 回報錯誤訊息，並把逐字稿原文回給使用者（逐字稿已花成本取得，不浪費）。

### 回覆格式
四則文字訊息，順序：
1. 📌 重點整理
2. 💭 情緒分析
3. 💬 回覆建議（每則建議以編號分段）
4. 📝 潤飾逐字稿（超過 5,000 字時截斷並註明「已截斷」）

每則都 ≤ 5,000 字。

### 程式結構（模組邊界）
- `LineSignature`：驗簽（純函式，可單元測試）。
- `LineWebhook`：事件 JSON 解碼（Codable）。
- `LineClient`：下載內容、transcoding 輪詢、reply、push、loading。
- `Transcriber`：音檔 URL → 逐字稿字串（protocol，方便測試替身）。
- `Analyzer`：逐字稿 → 分析結果（protocol；實作為 Claude）。
- `MessageFormatter`：分析結果 → `[String]`（含 5,000 字截斷，純函式）。
- `Pipeline`：串接上述並實作時間策略與錯誤處理。
- `Config`：讀 `.env`/環境變數。

### 測試與驗證
- 單元測試（swift-testing 或 XCTest）：驗簽、事件解碼、formatter 截斷、時間策略（reply vs push 的選擇）。
- 開發用 CLI 子命令 `murmur transcribe <file>` 與 `murmur analyze <file>`：直接用 `~/Downloads/_38494212.m4a`（約 11 分 16 秒，16kHz mono AAC）實跑轉文字與完整分析，不經 LINE。測試音檔**不複製進 repo**。
- 端對端：ngrok + 真實 LINE channel，由使用者轉傳語音驗證（需要使用者提供 channel 憑證）。

## 補充決定（builder check 後，標 [Claude] 者為 Claude 的決定）

- **時間預算計時範圍** [Claude]：50 秒從收到 webhook 起算，包含 loading、下載輪詢、轉文字、分析；成功與錯誤訊息都用同一個計時器判斷 reply 或 push。輪詢逾時視為錯誤，按同一規則回報。
- **push 使用** （使用者已同意 fallback）：超過 50 秒才用 push。實作初期先用測試音檔量測「轉文字＋分析」總耗時並寫入 README；若常態超過 50 秒，再回頭與使用者討論合併訊息則數。push 的計費方式（每個請求或每則泡泡）未確認，實作時查證並記錄。
- **Tunnel** （使用者確認）：ngrok，使用免費固定網域，webhook URL 只需設定一次。免費版固定網域與額度細節實作時以官方文件確認。
- **執行方式** [Claude]：先手動啟動（`swift run murmur serve` 或建置後的執行檔），不做 launchd 常駐；之後需要再加。
- **取得 userId** [Claude]：任何不在白名單的來訊都在 log 印出 userId（不回覆、不呼叫付費 API）。`ALLOWED_USER_IDS` 為空時同樣只記 log，使用者看 log 把自己的 userId 填入 `.env`。
- **語音辨識授權** [Claude]：CLI 執行檔可能需要 Info.plist（`NSSpeechRecognitionUsageDescription`）才能取得授權。後備順序：(1) 以 linker `-sectcreate __TEXT __info_plist` 把 Info.plist 嵌入執行檔；(2) 仍不行則包成最小 `.app` bundle。實作計畫的**第一個任務**就是用測試音檔驗證這件事，結果決定後續結構。SpeechAnalyzer 需要的 zh-TW 語言資源，透過 `AssetInventory` 在首次執行時下載。
- **繁體保證** [Claude]：逐字稿送進 Claude 前，先用 Foundation 的 `StringTransform("Hans-Hant")` 轉繁體；system prompt 也要求繁體中文輸出；Claude 回傳結果也再轉一次作為保險。
- **並行與重送** [Claude]：事件交給單一序列佇列（actor）依序處理，避免同時跑多個辨識與分析；用 `webhookEventId` 在記憶體中去重（保留最近約 1,000 筆），`deliveryContext.isRedelivery` 為 true 且已處理過的事件直接略過，避免重複花 credit。
- **非 m4a 音檔** [Claude]：依 `Content-Type` 決定副檔名，交給 AVFoundation 讀取；無法讀取時回報錯誤。

## 留給實作者決定
- Hummingbird 的具體 API 用法、背景 Task 的組織方式。
- 輪詢的精確間隔與上限、HTTP timeout 數值。
- system prompt 的確切措辭。
- log 格式（至少記錄每個階段耗時，方便驗證 50 秒預算）。
- 單元測試框架選擇。
