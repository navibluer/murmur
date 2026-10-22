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
}
