import Foundation
import Testing
@testable import MurmurCore

@Suite struct ConfigTests {
    let base = [
        "LINE_CHANNEL_SECRET": "s",
        "LINE_CHANNEL_ACCESS_TOKEN": "t",
        "ANTHROPIC_API_KEY": "k",
    ]

    @Test func dotEnvParse() {
        let r = DotEnv.parse("A=1\n# c\nB=\"x y\"\n")
        #expect(r == ["A": "1", "B": "x y"])
    }

    @Test func missingRequiredThrows() {
        var env = base
        env["ANTHROPIC_API_KEY"] = nil
        #expect(throws: ConfigError.self) { try Config.load(env: env) }
        env["ANTHROPIC_API_KEY"] = ""
        #expect(throws: ConfigError.self) { try Config.load(env: env) }
    }

    @Test func allowedUsers() throws {
        var env = base
        env["ALLOWED_USER_IDS"] = "U1, U2,,"
        #expect(try Config.load(env: env).allowedUserIDs == ["U1", "U2"])
        #expect(try Config.load(env: base).allowedUserIDs.isEmpty)
    }

    @Test func defaults() throws {
        let c = try Config.load(env: base)
        #expect(c.port == 47821)
        #expect(c.claudeModel == "claude-sonnet-5-5")
    }

    @Test func workspaceID() throws {
        #expect(try Config.load(env: base).anthropicWorkspaceID == nil)
        var env = base
        env["ANTHROPIC_WORKSPACE_ID"] = ""
        #expect(try Config.load(env: env).anthropicWorkspaceID == nil)
        env["ANTHROPIC_WORKSPACE_ID"] = "wrkspc_1"
        #expect(try Config.load(env: env).anthropicWorkspaceID == "wrkspc_1")
    }

    @Test func speechLocaleDefaultsAndOverride() throws {
        #expect(try Config.load(env: base).speechLocale == "zh-TW")
        var env = base
        env["SPEECH_LOCALE"] = "en-US"
        #expect(try Config.load(env: env).speechLocale == "en-US")
        env["SPEECH_LOCALE"] = ""
        #expect(try Config.load(env: env).speechLocale == "zh-TW")
    }

    @Test func seedCategoriesParsing() throws {
        #expect(try Config.load(env: base).seedCategories == RecordStoreDefaults.seedCategories)
        var env = base
        env["SEED_CATEGORIES"] = " 工作 ,生活,,工作 , 學習 "
        #expect(try Config.load(env: env).seedCategories == ["工作", "生活", "學習"])
        env["SEED_CATEGORIES"] = " , "
        #expect(try Config.load(env: env).seedCategories == RecordStoreDefaults.seedCategories)
    }

    @Test func contextFileExistsIsTrimmed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("my.md")
        try "\n服務的使用者是「小明」。\n\n".write(to: f, atomically: true, encoding: .utf8)
        var env = base
        env["CONTEXT_FILE"] = f.path
        let c = try Config.load(env: env)
        #expect(c.context == "服務的使用者是「小明」。")
        #expect(c.contextFile == f.path)
    }

    @Test func contextFileMissingOrEmptyIsNil() throws {
        var env = base
        env["CONTEXT_FILE"] = "/nonexistent/murmur-context.md"
        #expect(try Config.load(env: env).context == nil)
        #expect(try Config.load(env: base).contextFile == "context.md")
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-empty-\(UUID().uuidString).md")
        try " \n ".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        env["CONTEXT_FILE"] = f.path
        #expect(try Config.load(env: env).context == nil)
    }

    @Test func contextFileExpandsTilde() throws {
        let name = "murmur-ctx-\(UUID().uuidString).md"
        let f = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        try "背景".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        var env = base
        env["CONTEXT_FILE"] = "~/" + name
        #expect(try Config.load(env: env).context == "背景")
    }
}
