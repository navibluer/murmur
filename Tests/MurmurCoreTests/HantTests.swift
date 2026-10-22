import Testing
@testable import MurmurCore

@Suite struct HantTests {
    @Test func convertsSimplifiedToTraditional() {
        #expect(Hant.convert("这是简体中文") == "這是簡體中文")
    }

    @Test func keepsTraditionalUnchanged() {
        #expect(Hant.convert("已經是繁體") == "已經是繁體")
    }

    @Test func doesNotCorruptTraditionalWithAmbiguousChars() {
        #expect(Hant.convert("只要你願意，這件事就說定了") == "只要你願意，這件事就說定了")
    }
}
