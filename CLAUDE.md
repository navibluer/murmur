# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Murmur lets people avoid listening to emotionally intense LINE voice messages: forward one to the bot and get a clean transcript (plus a faithful one during the trial), sentiment analysis, and strategy-labeled reply suggestions. Personal context lives in the git-ignored context.md (see context.example.md).

## Commands

Swift package (SwiftPM, macOS 26, swift-tools 6.2). Library `MurmurCore`, executable `murmur`, tests `MurmurCoreTests` (swift-testing).

```sh
swift build
swift test                           # all tests
swift test --filter ServerTests      # one suite (or Suite/testName)
swift run murmur transcribe <file>   # speech-to-text only
swift run murmur analyze <file>      # transcribe + Claude analysis (needs ANTHROPIC_API_KEY)
swift run murmur serve               # LINE webhook server, 127.0.0.1:47821
swift run murmur backfill <id>...    # re-download old LINE voice messages by message ID and save to the CSV (no LINE messages sent)
scripts/murmurctl install|status|logs|restart|uninstall   # launchd background service (serve + ngrok), logs in ~/Library/Logs/murmur
```

Config comes from `.env` in the cwd merged with process env (env wins); see `.env.example`. Never print `.env` values.

## Architecture (Sources/MurmurCore)

- `Config` — `.env` parsing (`DotEnv`) and typed settings.
- `LineSignature` — HMAC-SHA256 webhook signature check.
- `LineWebhook` — Decodable webhook payload/event types.
- `LineClient` — LINE API (content download with transcode polling, reply/push/loading).
- `Transcriber` — `AppleTranscriber` (SpeechAnalyzer, locale from `SPEECH_LOCALE` default zh-TW, Hant conversion only for `zh*`).
- `Analyzer` — `ClaudeAnalyzer` (Claude API: polished text, sentiment, strategy-labelled replies `[Reply{label,text}]`, category). Per-user context comes from an optional gitignored `context.md` (`CONTEXT_FILE`, see `context.example.md`), appended to the system prompt as `【使用者情境】`; personal settings (`NGROK_URL`, `SEED_CATEGORIES`, `SPEECH_LOCALE`) live in `.env`.
- `MessageFormatter` — splits analysis into 3 LINE messages (transcript + category, sentiment, numbered `【label】` replies).
- `RecordStore` — `CSVRecordStore`：每則語音分析存成 CSV（預設 `data/records.csv`，`RECORDS_PATH` 可改；UTF-8 BOM、RFC 4180、欄位 `時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議`；一律以表頭判斷格式（舊 v1 含「重點整理」7 欄、v2 6 欄與新格式 v3 欄位數可能相同），舊檔於 `serve` 啟動或首次寫入時自動遷移並留 `.bak`）。指紋＝原始逐字稿 SHA256 前 16 hex，重複語音沿用第一筆紀錄不再呼叫 Claude；`categories()` ＝ seed ∪ 檔案已出現分類。
- `Pipeline` — actor: whitelist, dedup, reply-vs-push time policy, error handling; serializes events.
- `Server` — Hummingbird 2 app: `POST /webhook` verifies signature on raw body, returns 200 at once and processes events in a background `Task`; `GET /health`.

`Sources/murmur/main.swift` wires subcommands; `Info.plist` is embedded via linker flags for speech authorization. Use `pnpm` for any JS tooling.
