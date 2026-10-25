import Testing
@testable import MurmurCore

@Suite struct MessageFormatterTests {
    let sample = Analysis(
        polished: "潤飾後的逐字稿", summary: "- 重點一\n- 重點二", sentiment: "整體平靜",
        replies: ["好的，我知道了", "晚點回你"], category: "家庭生活")

    @Test func producesFourMessagesInOrder() {
        let m = MessageFormatter.format(sample)
        #expect(m.count == 4)
        let d = "━━━━━━━━━━"
        #expect(m[0] == "💡【重點整理】\n\(d)\n🏷️ 分類：家庭生活\n\n- 重點一\n- 重點二")
        #expect(m[0].contains("🏷️ 分類："))
        #expect(m[1] == "🎙️【逐字稿】\n\(d)\n潤飾後的逐字稿")
        #expect(m[2] == "🌡️【情緒分析】\n\(d)\n整體平靜")
        #expect(m[3].hasPrefix("🪄【回覆建議】\n\(d)\n1. "))
    }

    @Test func repliesAreNumbered() {
        let m = MessageFormatter.format(sample)
        #expect(m[3].contains("1. 好的，我知道了"))
        #expect(m[3].contains("2. 晚點回你"))
    }

    @Test func emptyFieldsBecomeNone() {
        let a = Analysis(polished: "", summary: "", sentiment: "  ", replies: [])
        let m = MessageFormatter.format(a)
        #expect(m.count == 4)
        for msg in m {
            #expect(msg.contains("（無）"))
            #expect(!msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func truncatesLongPolishedByUTF16AndKeepsGraphemeIntact() {
        let family = "👨‍👩‍👧"
        let long = String(repeating: family + "中文", count: 6000)
        let m = MessageFormatter.format(Analysis(polished: long, summary: "s", sentiment: "x", replies: ["r"]))
        #expect(m[1].utf16.count <= 5000)
        #expect(m[1].hasSuffix("…（已截斷）"))
        let body = String(m[1].dropLast("…（已截斷）".count))
        let last = body.last!
        #expect(last == "文" || last == Character(family))
        #expect(!body.hasSuffix("\u{200D}"))
    }

    @Test func shortTextNotTruncated() {
        #expect(MessageFormatter.truncate("abc") == "abc")
    }
}
