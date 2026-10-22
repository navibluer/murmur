# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Murmur captures voice messages from LINE Desktop chats and turns them into transcripts, summaries, sentiment insights, and suggested replies.

## Commands

Swift package (SwiftPM, macOS 26, swift-tools 6.2). Library `MurmurCore`, executable `murmur`, tests `MurmurCoreTests` (swift-testing).

```sh
swift build
swift test                           # all tests
swift test --filter ServerTests      # one suite (or Suite/testName)
swift run murmur transcribe <file>   # speech-to-text only
swift run murmur analyze <file>      # transcribe + Claude analysis (needs ANTHROPIC_API_KEY)
swift run murmur serve               # LINE webhook server, 127.0.0.1:47821
```

Config comes from `.env` in the cwd merged with process env (env wins); see `.env.example`. Never print `.env` values.

## Architecture (Sources/MurmurCore)

- `Config` — `.env` parsing (`DotEnv`) and typed settings.
- `LineSignature` — HMAC-SHA256 webhook signature check.
- `LineWebhook` — Decodable webhook payload/event types.
- `LineClient` — LINE API (content download with transcode polling, reply/push/loading).
- `Transcriber` — `AppleTranscriber` (SpeechAnalyzer zh-TW, Hant conversion).
- `Analyzer` — `ClaudeAnalyzer` (Claude API: polished text, summary, sentiment, replies).
- `MessageFormatter` — splits analysis into LINE messages.
- `Pipeline` — actor: whitelist, dedup, reply-vs-push time policy, error handling; serializes events.
- `Server` — Hummingbird 2 app: `POST /webhook` verifies signature on raw body, returns 200 at once and processes events in a background `Task`; `GET /health`.

`Sources/murmur/main.swift` wires subcommands; `Info.plist` is embedded via linker flags for speech authorization. Use `pnpm` for any JS tooling.
