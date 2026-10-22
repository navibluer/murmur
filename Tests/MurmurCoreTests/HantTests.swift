import Testing
@testable import MurmurCore

@Suite struct HantTests {
    @Test func convertsSimplifiedToTraditional() {
        #expect(Hant.convert("这是简体中文") == "這是簡體中文")
    }

    @Test func keepsTraditionalUnchanged() {
        #expect(Hant.convert("已經是繁體") == "已經是繁體")
    }
}
