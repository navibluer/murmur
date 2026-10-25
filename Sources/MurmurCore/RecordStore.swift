import CryptoKit
import Foundation

public enum RecordStoreDefaults {
    public static let seedCategories = ["家庭生活", "健康醫療", "金錢財務", "工作事業", "閒聊問候"]
    public static let defaultPath = "data/records.csv"
}

public struct Record: Equatable, Sendable {
    public var time: String
    public var fingerprint: String
    public var analysis: Analysis

    public init(time: String, fingerprint: String, analysis: Analysis) {
        self.time = time
        self.fingerprint = fingerprint
        self.analysis = analysis
    }

    /// 原始辨識逐字稿的 SHA256 前 16 個 hex 字元。
    public static func fingerprint(of transcript: String) -> String {
        SHA256.hash(data: Data(transcript.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 毫秒 timestamp → `yyyy-MM-dd HH:mm`（24 小時制，預設系統時區）。
    public static func formatTime(milliseconds: Int64, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}

public protocol RecordStore: Sendable {
    func categories() throws -> [String]
    func find(fingerprint: String) throws -> Record?
    func append(_ r: Record) throws
}

/// RFC 4180 CSV 編碼與解析。
public enum CSV {
    public static func encode(_ fields: [String]) -> String {
        fields.map { f in
            f.unicodeScalars.contains(where: { ",\"\n\r".unicodeScalars.contains($0) })
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : f
        }.joined(separator: ",") + "\r\n"
    }

    /// 解析整份 CSV（容許開頭 BOM、`\r\n` 或 `\n` 列結尾、引號內換行與 `""`）。
    public static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var wasQuoted = false
        var pendingQuote = false  // 引號內剛讀到一個 `"`，需看下一個字元決定是跳脫或結尾
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        for c in scalars {
            if pendingQuote {
                pendingQuote = false
                if c == "\"" { field.append(c); continue }
                inQuotes = false
            }
            if inQuotes {
                if c == "\"" { pendingQuote = true } else { field.append(c) }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !wasQuoted:
                inQuotes = true
                wasQuoted = true
            case ",": endField()
            case "\n": endRow()
            case "\r": break
            default: field.append(c)
            }
        }
        if pendingQuote { inQuotes = false }
        if inQuotes { throw CSVError.unterminatedQuote }
        if !field.isEmpty || wasQuoted || !row.isEmpty { endRow() }
        return rows
    }
}

public enum CSVError: Error, Equatable {
    case unterminatedQuote
}

public final class CSVRecordStore: RecordStore, @unchecked Sendable {
    static let header = ["時間", "指紋", "分類", "重點整理", "逐字稿", "情緒分析", "回覆建議"]
    let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func categories() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out = RecordStoreDefaults.seedCategories
        for r in try readAll() where !r.analysis.category.isEmpty && !out.contains(r.analysis.category) {
            out.append(r.analysis.category)
        }
        return out
    }

    public func find(fingerprint: String) throws -> Record? {
        lock.lock(); defer { lock.unlock() }
        return try readAll().first { $0.fingerprint == fingerprint }
    }

    public func append(_ r: Record) throws {
        lock.lock(); defer { lock.unlock() }
        if try readAll().contains(where: { $0.fingerprint == r.fingerprint }) { return }
        let fm = FileManager.default
        let row = CSV.encode([
            r.time, r.fingerprint, r.analysis.category, r.analysis.summary, r.analysis.polished,
            r.analysis.sentiment, Self.joinReplies(r.analysis.replies),
        ])
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data((CSV.encode(Self.header) + row).utf8))
            try data.write(to: url)
        } else {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(row.utf8))
        }
    }

    private func readAll() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return try CSV.parse(text).dropFirst().compactMap { f in
            guard f.count >= 7 else { return nil }
            return Record(
                time: f[0], fingerprint: f[1],
                analysis: Analysis(
                    polished: f[4], summary: f[3], sentiment: f[5], replies: Self.splitReplies(f[6]), category: f[2]))
        }
    }

    static func joinReplies(_ replies: [String]) -> String {
        replies.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// 還原 `1. …\n2. …`；只有依序編號（1、2、3…）開頭的行才算新的一則，其餘行屬於上一則的換行內容。
    static func splitReplies(_ s: String) -> [String] {
        var out: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let prefix = "\(out.count + 1). "
            if line.hasPrefix(prefix) {
                out.append(String(line.dropFirst(prefix.count)))
            } else if !out.isEmpty {
                out[out.count - 1] += "\n" + line
            }
        }
        return out
    }
}
