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

    public init(
        lineChannelSecret: String, lineChannelAccessToken: String, anthropicAPIKey: String,
        allowedUserIDs: Set<String> = [], claudeModel: String = "claude-sonnet-5-5", port: Int = 47821
    ) {
        self.lineChannelSecret = lineChannelSecret
        self.lineChannelAccessToken = lineChannelAccessToken
        self.anthropicAPIKey = anthropicAPIKey
        self.allowedUserIDs = allowedUserIDs
        self.claudeModel = claudeModel
        self.port = port
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
        return Config(
            lineChannelSecret: try required("LINE_CHANNEL_SECRET"),
            lineChannelAccessToken: try required("LINE_CHANNEL_ACCESS_TOKEN"),
            anthropicAPIKey: try required("ANTHROPIC_API_KEY"),
            allowedUserIDs: Set(ids), claudeModel: model, port: port)
    }
}
