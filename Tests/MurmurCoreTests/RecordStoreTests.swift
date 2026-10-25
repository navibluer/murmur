import Foundation
import Testing
@testable import MurmurCore

@Suite struct RecordStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    var url: URL { dir.appendingPathComponent("sub/records.csv") }

    func analysis(category: String = "家庭生活", polished: String = "你好") -> Analysis {
        Analysis(polished: polished, summary: "- 重點", sentiment: "平靜", replies: ["好", "晚點回"], category: category)
    }

    @Test func newFileHasBOMAndHeader() throws {
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "2026-01-02 03:04", fingerprint: "abc", analysis: analysis()))
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("時間,指紋,分類,重點整理,逐字稿,情緒分析,回覆建議\r\n"))
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func roundTripWithSpecialCharacters() throws {
        let store = CSVRecordStore(url: url)
        let a = Analysis(
            polished: "他說：\"好\", 然後\n換行\r\n再一行", summary: "- a,b\n- \"c\"",
            sentiment: "情緒, \"複雜\"", replies: ["1. 開頭像編號", "含\n換行的回覆"], category: "閒聊問候")
        let r = Record(time: "2026-01-02 03:04", fingerprint: "f1", analysis: a)
        try store.append(r)
        try store.append(Record(time: "2026-01-02 03:05", fingerprint: "f2", analysis: analysis()))
        let back = try #require(try CSVRecordStore(url: url).find(fingerprint: "f1"))
        #expect(back.time == r.time)
        #expect(back.analysis.category == "閒聊問候")
        #expect(back.analysis.summary == a.summary)
        #expect(back.analysis.sentiment == a.sentiment)
        #expect(back.analysis.replies == a.replies)
        // \r\n 在逐字稿內會被保留（解析器以 unicodeScalars 處理）
        #expect(back.analysis.polished == a.polished)
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
        let row = CSV.encode(["t", "old", "家庭生活", "s", "p", "x", "1. r"])
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((CSV.encode(CSVRecordStore.header) + row.dropLast(2)).utf8))
        try data.write(to: url)
        let store = CSVRecordStore(url: url)
        try store.append(Record(time: "t", fingerprint: "new", analysis: analysis()))
        #expect(try store.find(fingerprint: "old") != nil && store.find(fingerprint: "new") != nil)
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
            #expect(text.hasPrefix("時間,指紋,分類,重點整理,逐字稿,情緒分析,回覆建議\r\n"))
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func formulaLikeFieldsAreEscapedAndRoundTrip() throws {
        let store = CSVRecordStore(url: url)
        let a = Analysis(polished: "=SUM(1)", summary: "- 重點\n- 二", sentiment: "+1", replies: ["@某人"], category: "家庭生活")
        try store.append(Record(time: "t", fingerprint: "f", analysis: a))
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(raw.contains(",\" - 重點\n- 二\","))
        #expect(raw.contains(", =SUM(1),"))
        let back = try #require(try store.find(fingerprint: "f"))
        #expect(back.analysis.summary == a.summary && back.analysis.polished == a.polished)
        #expect(back.analysis.sentiment == "+1")
    }
}
