import Foundation
import MurmurCore

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "transcribe" || args[1] == "analyze" else {
    err("用法：murmur transcribe <音檔> | murmur analyze <音檔>")
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
        let analysis = try await ClaudeAnalyzer(apiKey: key, model: model, workspaceID: env["ANTHROPIC_WORKSPACE_ID"]).analyze(transcript: text)
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
