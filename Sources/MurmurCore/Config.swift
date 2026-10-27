import Foundation

public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

public enum ConfigError: Error, Equatable {
    case missing(String)
}

public struct Config: Sendable {
    public var lineChannelSecret: String
    public var lineChannelAccessToken: String
    public var anthropicAPIKey: String
    public var allowedUserIDs: Set<String>
    public var claudeModel: String
    public var port: Int
    public var anthropicWorkspaceID: String?
    public var recordsPath: String
    public var contextFile: String
    public var context: String?
    public var seedCategories: [String]
    public var speechLocale: String

    public init(
        lineChannelSecret: String, lineChannelAccessToken: String, anthropicAPIKey: String,
        allowedUserIDs: Set<String> = [], claudeModel: String = "claude-sonnet-5-5", port: Int = 47821,
        anthropicWorkspaceID: String? = nil, recordsPath: String = RecordStoreDefaults.defaultPath,
        contextFile: String = "context.md", context: String? = nil,
        seedCategories: [String] = RecordStoreDefaults.seedCategories, speechLocale: String = "zh-TW"
    ) {
        self.lineChannelSecret = lineChannelSecret
        self.lineChannelAccessToken = lineChannelAccessToken
        self.anthropicAPIKey = anthropicAPIKey
        self.allowedUserIDs = allowedUserIDs
        self.claudeModel = claudeModel
        self.port = port
        self.anthropicWorkspaceID = anthropicWorkspaceID
        self.recordsPath = recordsPath
        self.contextFile = contextFile
        self.context = context
        self.seedCategories = seedCategories
        self.speechLocale = speechLocale
    }

    /// 逗號分隔、trim、去空、去重；結果為空時用預設五類。
    public static func parseSeedCategories(_ raw: String?) -> [String] {
        var seeds: [String] = []
        for c in (raw ?? "").split(separator: ",") {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !seeds.contains(t) { seeds.append(t) }
        }
        return seeds.isEmpty ? RecordStoreDefaults.seedCategories : seeds
    }

    /// 讀取情境檔（支援 `~`）；不存在、讀不到或內容全為空白時回傳 nil。
    public static func readContext(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: expanded, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func load(env: [String: String]) throws -> Config {
        func required(_ key: String) throws -> String {
            guard let v = env[key], !v.isEmpty else { throw ConfigError.missing(key) }
            return v
        }
        let ids = (env["ALLOWED_USER_IDS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let model = env["CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5"
        let port = env["PORT"].flatMap { Int($0) } ?? 47821
        let contextFile = env["CONTEXT_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "context.md"
        return Config(
            lineChannelSecret: try required("LINE_CHANNEL_SECRET"),
            lineChannelAccessToken: try required("LINE_CHANNEL_ACCESS_TOKEN"),
            anthropicAPIKey: try required("ANTHROPIC_API_KEY"),
            allowedUserIDs: Set(ids), claudeModel: model, port: port,
            anthropicWorkspaceID: env["ANTHROPIC_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 },
            recordsPath: env["RECORDS_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? RecordStoreDefaults.defaultPath,
            contextFile: contextFile, context: readContext(path: contextFile),
            seedCategories: parseSeedCategories(env["SEED_CATEGORIES"]),
            speechLocale: env["SPEECH_LOCALE"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-TW")
    }
}
