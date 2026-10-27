import Testing
@testable import MurmurCore

@Suite struct MessageFormatterTests {
    let sample = Analysis(
        polished: "潤飾後的逐字稿", sentiment: "整體平靜",
        replies: [Reply(label: "簡短收到", text: "好的，我知道了"), Reply(label: "延後處理", text: "晚點回你\n我想一下")],
        category: "家庭生活")

    @Test func producesThreeMessagesInOrder() {
        let m = MessageFormatter.format(sample)
        #expect(m.count == 3)
        let d = "━━━━━━━━━━"
        #expect(m[0] == "🎙️【逐字稿】\n\(d)\n🏷️ 分類：家庭生活\n\n潤飾後的逐字稿")
        #expect(m[0].contains("🏷️ 分類："))
        #expect(m[1] == "🌡️【情緒分析】\n\(d)\n整體平靜")
        #expect(m[2].hasPrefix("🪄【回覆建議】\n\(d)\n1. 【簡短收到】\n好的，我知道了"))
        #expect(!m.joined().contains("重點整理"))
    }

    @Test func repliesAreNumberedWithLabels() {
        let m = MessageFormatter.format(sample)
        #expect(m[2].hasSuffix("1. 【簡短收到】\n好的，我知道了\n\n2. 【延後處理】\n晚點回你\n我想一下"))
    }

    @Test func emptyFieldsBecomeNone() {
        let a = Analysis(polished: "", sentiment: "  ", replies: [])
        let m = MessageFormatter.format(a)
        #expect(m.count == 3)
        for msg in m {
            #expect(msg.contains("（無）"))
            #expect(!msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func truncatesLongPolishedByUTF16AndKeepsGraphemeIntact() {
        let family = "👨‍👩‍👧"
        let long = String(repeating: family + "中文", count: 6000)
        let m = MessageFormatter.format(Analysis(polished: long, sentiment: "x", replies: [Reply(label: "l", text: "r")]))
        #expect(m[0].utf16.count <= 5000)
        #expect(m[0].hasSuffix("…（已截斷）"))
        let body = String(m[0].dropLast("…（已截斷）".count))
        let last = body.last!
        #expect(last == "文" || last == Character(family))
        #expect(!body.hasSuffix("\u{200D}"))
    }

    @Test func shortTextNotTruncated() {
        #expect(MessageFormatter.truncate("abc") == "abc")
    }
}
