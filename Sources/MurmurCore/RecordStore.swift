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
    static let formulaTriggers: Set<Unicode.Scalar> = ["=", "+", "-", "@"]

    /// 還原 `encode` 為避免 Excel 公式而補的前導空白。
    static func unescapeFormula(_ f: String) -> String {
        let u = Array(f.unicodeScalars)
        if u.count >= 2, u[0] == " ", formulaTriggers.contains(u[1]) { return String(String.UnicodeScalarView(u.dropFirst())) }
        return f
    }

    public static func encode(_ fields: [String]) -> String {
        fields.map { raw in
            // Excel 會把 = + - @ 開頭的儲存格當公式；前面補一個空白，讀回時還原
            let f = formulaTriggers.contains(raw.unicodeScalars.first ?? "a") ? " " + raw : raw
            return f.unicodeScalars.contains(where: { ",\"\n\r".unicodeScalars.contains($0) })
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : f
        }.joined(separator: ",") + "\r\n"
    }

    /// 解析整份 CSV（容許開頭 BOM、`\r\n` 或 `\n` 列結尾、引號內換行與 `""`）。
    public static func parse(_ text: String) throws -> [[String]] {
        let r = parseCore(text)
        if r.openQuote { throw CSVError.unterminatedQuote }
        return r.rows
    }

    /// 容錯版：引號未閉合時（例如寫入中途被中斷）丟棄最後那段殘列，其餘照常回傳。
    static func parseTolerant(_ text: String) -> (rows: [[String]], openQuote: Bool) {
        parseCore(text)
    }

    private static func parseCore(_ text: String) -> (rows: [[String]], openQuote: Bool) {
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
        if inQuotes { return (rows, true) }
        if !field.isEmpty || wasQuoted || !row.isEmpty { endRow() }
        return (rows, false)
    }
}

public enum CSVError: Error, Equatable {
    case unterminatedQuote
}

public final class CSVRecordStore: RecordStore, @unchecked Sendable {
    static let header = ["時間", "指紋", "分類", "逐字稿", "情緒分析", "回覆建議"]
    static let legacyHeader = ["時間", "指紋", "分類", "重點整理", "逐字稿", "情緒分析", "回覆建議"]
    let url: URL
    let seedCategories: [String]
    private let lock = NSLock()

    public init(url: URL, seedCategories: [String] = RecordStoreDefaults.seedCategories) {
        self.url = url
        self.seedCategories = seedCategories
    }

    public func categories() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out = seedCategories
        for r in readAll() where !r.analysis.category.isEmpty && !out.contains(r.analysis.category) {
            out.append(r.analysis.category)
        }
        return out
    }

    public func find(fingerprint: String) throws -> Record? {
        lock.lock(); defer { lock.unlock() }
        return readAll().first { $0.fingerprint == fingerprint }
    }

    public func append(_ r: Record) throws {
        lock.lock(); defer { lock.unlock() }
        if readAll().contains(where: { $0.fingerprint == r.fingerprint }) { return }
        let fm = FileManager.default
        let row = Self.encodeRecord(r)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let headerLine = CSV.encode(Self.header)
        var existing = Data()
        if fm.fileExists(atPath: url.path) {
            existing = try Data(contentsOf: url)  // 讀不到就丟錯，不可當成空檔而覆寫歷史紀錄
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let body = existing.starts(with: bom) ? existing.dropFirst(3) : existing[...]
        if body.isEmpty {
            // 不存在、0 bytes 或只有 BOM：重寫 BOM + 表頭 + 此列
            try (bom + Data((headerLine + row).utf8)).write(to: url, options: .atomic)
            return
        }
        let text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(Self.legacyHeader.joined(separator: ",")) {
            try migrateLegacy(text: text, newRow: row)
            return
        }
        let hasHeader = text.hasPrefix(Self.header.joined(separator: ","))
        let closer: String
        if CSV.parseTolerant(text).openQuote {
            closer = "\"\r\n"  // 收掉未閉合引號的殘列，讓新列能正確讀回
        } else {
            closer = body.last == 0x0A ? "" : "\r\n"
        }
        if hasHeader {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data((closer + row).utf8))
        } else {
            // 缺表頭：整檔重寫為 BOM + 表頭 + 原內容 + 收尾 + 新列
            try (bom + Data(headerLine.utf8) + body + Data((closer + row).utf8)).write(to: url, options: .atomic)
        }
    }

    /// 檔案若是舊 7 欄格式就立即遷移（serve 啟動時呼叫）；回傳是否有遷移。
    @discardableResult
    public func migrateIfNeeded() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let text = String(decoding: body, as: UTF8.self)
        guard text.hasPrefix(Self.legacyHeader.joined(separator: ",")) else { return false }
        try migrateLegacy(text: text, newRow: "")
        return true
    }

    /// 舊 7 欄檔：先備份為 .bak（已存在則加時間戳記），再以 atomic 整檔重寫為新格式。
    private func migrateLegacy(text: String, newRow: String) throws {
        let fm = FileManager.default
        var bak = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
        if fm.fileExists(atPath: bak.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            bak = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).\(f.string(from: Date())).bak")
            var n = 1
            while fm.fileExists(atPath: bak.path) {
                bak = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).\(f.string(from: Date()))-\(n).bak")
                n += 1
            }
        }
        try fm.copyItem(at: url, to: bak)
        let rows = Self.records(from: CSV.parseTolerant(text).rows).map(Self.encodeRecord).joined()
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data((CSV.encode(Self.header) + rows + newRow).utf8)).write(to: url, options: .atomic)
    }

    static func encodeRecord(_ r: Record) -> String {
        CSV.encode([
            r.time, r.fingerprint, r.analysis.category, r.analysis.polished,
            r.analysis.sentiment, joinReplies(r.analysis.replies),
        ])
    }

    /// 讀取失敗或檔案損毀都當作盡力而為：略過壞列，不丟錯。
    private func readAll() -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.records(from: CSV.parseTolerant(String(decoding: data, as: UTF8.self)).rows)
    }

    /// 新格式 6 欄、舊格式 7 欄（丟掉重點整理）；其餘欄位數與表頭列略過。
    static func records(from rows: [[String]]) -> [Record] {
        rows.compactMap { raw in
            guard raw != header, raw != legacyHeader else { return nil }
            let f = raw.map(CSV.unescapeFormula)
            switch raw.count {
            case 6:
                return Record(
                    time: f[0], fingerprint: f[1],
                    analysis: Analysis(polished: f[3], sentiment: f[4], replies: splitReplies(f[5]), category: f[2]))
            case 7:
                return Record(
                    time: f[0], fingerprint: f[1],
                    analysis: Analysis(polished: f[4], sentiment: f[5], replies: splitReplies(f[6]), category: f[2]))
            default: return nil
            }
        }
    }

    static func joinReplies(_ replies: [Reply]) -> String {
        replies.enumerated().map { i, r in
            r.label.isEmpty ? "\(i + 1). \(r.text)" : "\(i + 1). 【\(r.label)】\(r.text)"
        }.joined(separator: "\n")
    }

    /// 還原 `1. 【標籤】…\n2. …`；只有依序編號（1、2、3…）開頭的行才算新的一則，其餘行屬於上一則的換行內容。
    /// 沒有【】的舊格式 label 為空字串。
    static func splitReplies(_ s: String) -> [Reply] {
        var raw: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let prefix = "\(raw.count + 1). "
            if line.hasPrefix(prefix) {
                raw.append(String(line.dropFirst(prefix.count)))
            } else if !raw.isEmpty {
                raw[raw.count - 1] += "\n" + line
            }
        }
        return raw.map { body in
            if body.hasPrefix("【"), let end = body.firstIndex(of: "】") {
                return Reply(label: String(body[body.index(after: body.startIndex)..<end]), text: String(body[body.index(after: end)...]))
            }
            return Reply(label: "", text: body)
        }
    }
}
