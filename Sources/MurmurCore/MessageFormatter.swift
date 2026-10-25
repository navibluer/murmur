import Foundation

public enum MessageFormatter {
    public static let limit = 5000
    static let suffix = "…（已截斷）"
    static let none = "（無）"
    static let divider = "━━━━━━━━━━"
    static let summaryHeader = "💡【重點整理】"
    static let transcriptHeader = "🎙️【逐字稿】"
    static let sentimentHeader = "🌡️【情緒分析】"
    static let repliesHeader = "🪄【回覆建議】"

    static func header(_ title: String) -> String { title + "\n" + divider + "\n" }

    public static func format(_ a: Analysis) -> [String] {
        let replies: String
        let cleaned = a.replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            replies = none
        } else {
            replies = cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
        }
        return [
            truncate(header(summaryHeader) + "🏷️ 分類：\(orNone(a.category))\n\n" + orNone(a.summary)),
            truncate(header(transcriptHeader) + orNone(a.polished)),
            truncate(header(sentimentHeader) + orNone(a.sentiment)),
            truncate(header(repliesHeader) + replies),
        ]
    }

    static func orNone(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? none : t
    }

    static func truncate(_ s: String, limit: Int = limit) -> String {
        if s.utf16.count <= limit { return s }
        let budget = limit - suffix.utf16.count
        var used = 0
        var out = ""
        for ch in s {
            let n = String(ch).utf16.count
            if used + n > budget { break }
            out.append(ch)
            used += n
        }
        return out + suffix
    }
}
