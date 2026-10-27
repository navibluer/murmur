import Foundation
import Testing
@testable import MurmurCore

@Suite struct RecordStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    var url: URL { dir.appendingPathComponent("sub/records.csv") }

    func analysis(category: String = "家庭生活", polished: String = "你好") -> Analysis {
        Analysis(polished: polished, clean: "精簡你好", sentiment: "平靜", replies: [Reply(label: "簡短收到", text: "好"), Reply(label: "延後處理", text: "晚點回")], category: category)
    }

    @Test func newFileHasBOMAndHeader() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "2026-01-02 03:04", fingerprint: "abc", analysis: analysis()))
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func roundTripWithSpecialCharacters() throws {
        let store = CSVRecordStore(url: url)
        let a = Analysis(
            polished: "他說：\"好\", 然後\n換行\r\n再一行",
            clean: "精簡, \"版\"\n換行",
            sentiment: "情緒, \"複雜\"",
            replies: [Reply(label: "設立,界線", text: "1. 開頭像編號"), Reply(label: "明確\"拒絕\"", text: "含\n換行,和\"引號\"的回覆")], category: "閒聊問候")
        let r = Record(time: "2026-01-02 03:04", fingerprint: "f1", analysis: a)
        try store.append(r)
        try store.append(Record(time: "2026-01-02 03:05", fingerprint: "f2", analysis: analysis()))
        let back = try #require(try CSVRecordStore(url: url).find(fingerprint: "f1"))
        #expect(back.time == r.time)
        #expect(back.analysis.category == "閒聊問候")
        #expect(back.analysis.sentiment == a.sentiment)
        #expect(back.analysis.replies == a.replies)
        // \r\n 在逐字稿內會被保留（解析器以 unicodeScalars 處理）
        #expect(back.analysis.polished == a.polished)
        #expect(back.analysis.clean == a.clean)
        #expect(try store.find(fingerprint: "nope") == nil)
    }

    @Test func duplicateFingerprintNotWritten() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t1", fingerprint: "same", analysis: analysis(polished: "第一次")))
        try store.append(Record(time: "t2", fingerprint: "same", analysis: analysis(polished: "第二次")))
        let rows = try CSV.parse(String(contentsOf: url, encoding: .utf8))
        #expect(rows.count == 2)  // 表頭 + 1 筆
        #expect(try store.find(fingerprint: "same")?.analysis.polished == "第一次")
    }

    @Test func categoriesMergeSeedAndFileWithoutDuplicates() throws {
        let store = CSVRecordStore(url: url)
        #expect(try store.categories() == RecordStoreDefaults.seedCategories)
        try store.append(Record(time: "t", fingerprint: "1", analysis: analysis(category: "旅遊計畫")))
        try store.append(Record(time: "t", fingerprint: "2", analysis: analysis(category: "健康醫療")))
        try store.append(Record(time: "t", fingerprint: "3", analysis: analysis(category: "學校事務")))
        try store.append(Record(time: "t", fingerprint: "4", analysis: analysis(category: "旅遊計畫")))
        #expect(try store.categories() == RecordStoreDefaults.seedCategories + ["旅遊計畫", "學校事務"])
        #expect(RecordStoreDefaults.seedCategories == ["家庭生活", "健康醫療", "金錢財務", "工作事業", "閒聊問候"])
    }

    @Test func fingerprintIs16HexOfSHA256() {
        // SHA256("abc") = ba7816bf8f01cfea...
        #expect(Record.fingerprint(of: "abc") == "ba7816bf8f01cfea")
    }

    @Test func formatTime() {
        let tz = TimeZone(identifier: "Asia/Taipei")!
        // 1692251666727 ms = 2023-08-17 05:54:26 UTC
        #expect(Record.formatTime(milliseconds: 1_692_251_666_727, timeZone: tz) == "2023-08-17 13:54")
        // 下午時段須為 24 小時制
        #expect(Record.formatTime(milliseconds: 1_692_251_666_727 + 8 * 3600_000, timeZone: tz) == "2023-08-17 21:54")
    }

    @Test func csvParserHandlesQuotesBOMAndCRLF() throws {
        let text = "\u{FEFF}a,b\r\n\"x,\"\"y\"\"\nz\",\"\"\r\n"
        #expect(try CSV.parse(text) == [["a", "b"], ["x,\"y\"\nz", ""]])
        #expect(CSV.encode(["x,\"y\"\nz", "plain", "a\rb"]) == "\"x,\"\"y\"\"\nz\",plain,\"a\rb\"\r\n")
    }

    @Test func recoversFromUnterminatedQuoteTail() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t", fingerprint: "old", analysis: analysis()))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("t,broken,分類,\"半列沒有結尾\r\n還有內容".utf8))
        try h.close()
        // 讀取不丟錯，舊紀錄仍在
        #expect(try store.find(fingerprint: "old") != nil)
        #expect(try store.categories().count == 5)
        try store.append(Record(time: "t", fingerprint: "new", analysis: analysis(category: "新類")))
        #expect(try store.find(fingerprint: "old") != nil)
        #expect(try store.find(fingerprint: "new")?.analysis.category == "新類")
    }

    @Test func skipsRowsWithWrongFieldCount() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t", fingerprint: "old", analysis: analysis()))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("a,b,c\r\n".utf8))
        try h.close()
        try store.append(Record(time: "t", fingerprint: "new", analysis: analysis()))
        #expect(try store.find(fingerprint: "old") != nil && store.find(fingerprint: "new") != nil)
    }

    @Test func appendAfterMissingTrailingNewline() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row = CSV.encode(["t", "old", "家庭生活", "c", "p", "x", "1. r"])
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((CSV.encode(CSVRecordStore.header) + row.dropLast(2)).utf8))
        try data.write(to: url)
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t", fingerprint: "new", analysis: analysis()))
        #expect(try store.find(fingerprint: "old") != nil && store.find(fingerprint: "new") != nil)
    }

    @Test func unreadableFileIsNotOverwritten() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "2026-01-02 03:04", fingerprint: "old", analysis: analysis()))
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)  // 只能寫、不能讀
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(throws: (any Error).self) {
            try store.append(Record(time: "2026-01-02 03:05", fingerprint: "new", analysis: analysis()))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func emptyOrBOMOnlyFileGetsHeader() throws {
        for initial in [Data(), Data([0xEF, 0xBB, 0xBF])] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try initial.write(to: url)
            let store = CSVRecordStore(url: url)
            try store.append(Record(time: "t", fingerprint: "n", analysis: analysis()))
            #expect(try store.find(fingerprint: "n") != nil)
            let data = try Data(contentsOf: url)
            #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
            let text = String(decoding: data.dropFirst(3), as: UTF8.self)
            #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func formulaLikeFieldsAreEscapedAndRoundTrip() throws {
        let store = CSVRecordStore(url: url)
        let a = Analysis(polished: "=SUM(1)\n二", sentiment: "+1", replies: [Reply(label: "-標籤", text: "@某人")], category: "家庭生活")
        try store.append(Record(time: "t", fingerprint: "f", analysis: a))
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(raw.contains(",\" =SUM(1)\n二\","))
        #expect(raw.contains(",\"1. 【-標籤】@某人\"") || raw.contains(",1. 【-標籤】@某人"))
        let back = try #require(try store.find(fingerprint: "f"))
        #expect(back.analysis.replies == a.replies && back.analysis.polished == a.polished)
        #expect(back.analysis.sentiment == "+1")
    }

    // MARK: 舊格式（v1 7 欄、v2 6 欄）遷移

    func writeLegacy(_ rows: [[String]], header: [String] = CSVRecordStore.headerV1) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var s = CSV.encode(header)
        for r in rows { s += CSV.encode(r) }
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(s.utf8)
        try data.write(to: url)
        return data
    }

    let legacyRows = [
        ["2026-01-01 10:00", "old1", "金錢財務", "- 重點, 一", "逐字稿一\n第二行", "情緒, \"複雜\"", "1. 好的\n2. 含\n換行的回覆"],
        ["2026-01-01 10:01", "old2", "家庭生活", "- 重點二", "逐字稿二", "平靜", "1. 晚點回"],
    ]

    let v2Rows = [
        ["2026-01-01 10:00", "old1", "金錢財務", "逐字稿一\n第二行", "情緒, \"複雜\"", "1. 好的\n2. 含\n換行的回覆"],
        ["2026-01-01 10:01", "old2", "家庭生活", "逐字稿二", "平靜", "1. 晚點回"],
    ]

    @Test func v3RoundTripIsNotMistakenForV1() throws {
        // v1 與 v3 都是 7 欄，必須以表頭區分：v3 檔的第 4 欄是精簡逐字稿，不能被當成重點整理丟掉
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t", fingerprint: "n", analysis: analysis()))
        #expect(try store.migrateIfNeeded() == false)
        #expect(try store.find(fingerprint: "n")?.analysis.clean == "精簡你好")
        #expect(try store.find(fingerprint: "n")?.analysis.polished == "你好")
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["records.csv"])
    }

    @Test func v1FileMigratesToV3KeepingAllFieldsWithEmptyClean() throws {
        let original = try writeLegacy(legacyRows)
        let store = CSVRecordStore(url: url)
        #expect(try store.migrateIfNeeded())
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        #expect(try Data(contentsOf: bak) == original)
        let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
        let rows = try CSV.parse(text)
        #expect(rows.count == 3 && rows.allSatisfy { $0.count == 7 })
        #expect(rows[1][3] == "")
        let o1 = try #require(try store.find(fingerprint: "old1"))
        #expect(o1.analysis.clean == "" && o1.analysis.polished == "逐字稿一\n第二行" && o1.analysis.category == "金錢財務")
        #expect(o1.analysis.sentiment == "情緒, \"複雜\"" && o1.analysis.replies.map(\.text) == ["好的", "含\n換行的回覆"])
        #expect(try store.migrateIfNeeded() == false)
    }

    @Test func v2FileMigratesToV3KeepingAllFieldsWithEmptyClean() throws {
        let original = try writeLegacy(v2Rows, header: CSVRecordStore.headerV2)
        let store = CSVRecordStore(url: url)
        // 遷移前也能讀
        #expect(try store.find(fingerprint: "old2")?.analysis.polished == "逐字稿二")
        #expect(try store.migrateIfNeeded())
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        #expect(try Data(contentsOf: bak) == original)
        let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
        let rows = try CSV.parse(text)
        #expect(rows.count == 3 && rows.allSatisfy { $0.count == 7 })
        let o1 = try #require(try store.find(fingerprint: "old1"))
        #expect(o1.analysis.clean == "" && o1.analysis.polished == "逐字稿一\n第二行" && o1.analysis.category == "金錢財務")
        #expect(o1.analysis.sentiment == "情緒, \"複雜\"" && o1.analysis.replies.map(\.text) == ["好的", "含\n換行的回覆"])
        #expect(try store.find(fingerprint: "old2")?.time == "2026-01-01 10:01")
    }

    @Test func appendMigratesV2FileWithBackup() throws {
        let original = try writeLegacy(v2Rows, header: CSVRecordStore.headerV2)
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "2026-02-02 02:02", fingerprint: "new1", analysis: analysis()))
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        #expect(try Data(contentsOf: bak) == original)
        let rows = try CSV.parse(String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self))
        #expect(rows.count == 4 && rows.allSatisfy { $0.count == 7 })
        #expect(try store.find(fingerprint: "old1")?.analysis.clean == "")
        #expect(try store.find(fingerprint: "new1")?.analysis.clean == "精簡你好")
    }

    @Test func legacyRowsReadWithEmptyLabels() throws {
        _ = try writeLegacy(legacyRows)
        let r = try #require(try CSVRecordStore(url: url).find(fingerprint: "old1"))
        #expect(r.analysis.polished == "逐字稿一\n第二行")
        #expect(r.analysis.sentiment == "情緒, \"複雜\"")
        #expect(r.analysis.category == "金錢財務")
        #expect(r.analysis.replies == [Reply(label: "", text: "好的"), Reply(label: "", text: "含\n換行的回覆")])
    }

    @Test func migrateIfNeededConvertsLegacyWithoutNewRow() throws {
        let original = try writeLegacy(legacyRows)
        let store = CSVRecordStore(url: url)
        #expect(try store.migrateIfNeeded())
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        #expect(try Data(contentsOf: bak) == original)
        let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
        #expect(try store.find(fingerprint: "old1")?.analysis.polished == "逐字稿一\n第二行")
        #expect(try store.find(fingerprint: "old2") != nil)
        #expect(try store.migrateIfNeeded() == false)  // 已是新格式，不再動
        #expect(try CSVRecordStore(url: dir.appendingPathComponent("none.csv")).migrateIfNeeded() == false)
    }

    @Test func appendMigratesLegacyFileWithBackup() throws {
        let original = try writeLegacy(legacyRows)
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "2026-02-02 02:02", fingerprint: "new1", analysis: analysis()))
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        #expect(try Data(contentsOf: bak) == original)
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,精簡逐字稿,逐字稿,情緒分析,回覆建議\r\n"))
        let rows = try CSV.parse(text)
        #expect(rows.count == 4 && rows.allSatisfy { $0.count == 7 })
        let o1 = try #require(try store.find(fingerprint: "old1"))
        #expect(o1.time == "2026-01-01 10:00" && o1.analysis.category == "金錢財務")
        #expect(o1.analysis.polished == "逐字稿一\n第二行" && o1.analysis.sentiment == "情緒, \"複雜\"")
        #expect(o1.analysis.replies.map(\.text) == ["好的", "含\n換行的回覆"])
        #expect(try store.find(fingerprint: "old2")?.analysis.polished == "逐字稿二")
        #expect(try store.find(fingerprint: "new1")?.analysis.replies.first?.label == "簡短收到")
        // 再次 append 不再遷移，也不產生新的備份
        try store.append(Record(time: "t", fingerprint: "new2", analysis: analysis()))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.sorted() == ["records.csv", "records.csv.bak"])
    }

    @Test func migrationDoesNotOverwriteExistingBackup() throws {
        _ = try writeLegacy(legacyRows)
        let bak = url.deletingLastPathComponent().appendingPathComponent("records.csv.bak")
        try Data("舊備份".utf8).write(to: bak)
        try CSVRecordStore(url: url).append(Record(time: "t", fingerprint: "n", analysis: analysis()))
        #expect(try Data(contentsOf: bak) == Data("舊備份".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.count == 3)
        #expect(files.contains { $0.hasPrefix("records.csv.") && $0.hasSuffix(".bak") && $0 != "records.csv.bak" })
    }

    @Test func splitRepliesParsesLabelsAndLegacy() {
        #expect(CSVRecordStore.splitReplies("1. 【簡短收到】好\n2. 【設立界線】不行\n再一行") == [
            Reply(label: "簡短收到", text: "好"), Reply(label: "設立界線", text: "不行\n再一行"),
        ])
        #expect(CSVRecordStore.splitReplies("1. 好\n2. 晚點") == [Reply(label: "", text: "好"), Reply(label: "", text: "晚點")])
    }

    @Test func customSeedOverridesDefaults() throws {
        let store = CSVRecordStore(url: url, seedCategories: ["工作", "生活"])
        #expect(try store.categories() == ["工作", "生活"])
        try store.append(Record(time: "t", fingerprint: "1", analysis: analysis(category: "生活")))
        try store.append(Record(time: "t", fingerprint: "2", analysis: analysis(category: "旅遊")))
        #expect(try store.categories() == ["工作", "生活", "旅遊"])
    }
}
