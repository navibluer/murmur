import Foundation
import MurmurCore

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments

if args.count >= 2, args[1] == "serve" {
    var env = ProcessInfo.processInfo.environment
    if let raw = try? String(contentsOfFile: ".env", encoding: .utf8) {
        env = DotEnv.parse(raw).merging(env) { _, processEnv in processEnv }
    }
    do {
        let config = try Config.load(env: env)
        if config.allowedUserIDs.isEmpty {
            err("警告：ALLOWED_USER_IDS 為空，所有訊息都會被拒絕；請傳訊給 bot，從 log 的「未授權的 userId」複製")
        }
        let pipeline = Pipeline(
            config: config,
            line: LineClient(accessToken: config.lineChannelAccessToken),
            transcriber: AppleTranscriber(),
            analyzer: ClaudeAnalyzer(
                apiKey: config.anthropicAPIKey, model: config.claudeModel, workspaceID: config.anthropicWorkspaceID),
            store: CSVRecordStore(url: URL(fileURLWithPath: (config.recordsPath as NSString).expandingTildeInPath)))
        err("murmur 監聽 127.0.0.1:\(config.port)（POST /webhook、GET /health）")
        try await buildApplication(config: config, pipeline: pipeline).runService()
    } catch {
        err("錯誤：\(error)")
        exit(1)
    }
    exit(0)
}

if args.count >= 2, args[1] == "backfill" {
    let ids = Array(args.dropFirst(2))
    guard !ids.isEmpty else {
        err("用法：murmur backfill <messageId> [<messageId> ...]")
        exit(64)
    }
    var env = ProcessInfo.processInfo.environment
    if let raw = try? String(contentsOfFile: ".env", encoding: .utf8) {
        env = DotEnv.parse(raw).merging(env) { _, processEnv in processEnv }
    }
    do {
        let config = try Config.load(env: env)
        let summary = await Backfill(
            line: LineClient(accessToken: config.lineChannelAccessToken),
            transcriber: AppleTranscriber(),
            analyzer: ClaudeAnalyzer(
                apiKey: config.anthropicAPIKey, model: config.claudeModel, workspaceID: config.anthropicWorkspaceID),
            store: CSVRecordStore(url: URL(fileURLWithPath: (config.recordsPath as NSString).expandingTildeInPath))
        ).run(ids: ids)
        exit(summary.failed > 0 ? 1 : 0)
    } catch {
        err("錯誤：\(error)")
        exit(1)
    }
}

guard args.count >= 3, args[1] == "transcribe" || args[1] == "analyze" else {
    err("用法：murmur transcribe <音檔> | murmur analyze <音檔> | murmur serve | murmur backfill <messageId>...")
    exit(64)
}
let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
let start = Date()
do {
    var env = ProcessInfo.processInfo.environment
    if let raw = try? String(contentsOfFile: ".env", encoding: .utf8) {
        env = DotEnv.parse(raw).merging(env) { _, processEnv in processEnv }
    }
    let key = env["ANTHROPIC_API_KEY"] ?? ""
    if args[1] == "analyze", key.isEmpty {
        err("錯誤：缺少 ANTHROPIC_API_KEY")
        exit(78)
    }
    let model = env["CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5"
    let text = try await AppleTranscriber().transcribe(fileURL: url)
    let t1 = Date().timeIntervalSince(start)
    if args[1] == "transcribe" {
        print(text)
        err(String(format: "transcribe: %.1fs", t1))
    } else {
        let t2Start = Date()
        let analysis = try await ClaudeAnalyzer(apiKey: key, model: model, workspaceID: env["ANTHROPIC_WORKSPACE_ID"]).analyze(
            transcript: text, categories: RecordStoreDefaults.seedCategories)
        let t2 = Date().timeIntervalSince(t2Start)
        for m in MessageFormatter.format(analysis) {
            print(m)
            print("\n-----\n")
        }
        err(String(format: "transcribe: %.1fs\nanalyze: %.1fs\ntotal: %.1fs", t1, t2, Date().timeIntervalSince(start)))
    }
} catch {
    err("錯誤：\(error)")
    exit(1)
}
