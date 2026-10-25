import Foundation
import Testing
@testable import MurmurCore

@Suite struct BackfillTests {
    let line = FakeLine()
    let tr = FakeTranscriber()
    let an = FakeAnalyzer()
    let store = FakeStore()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-\(UUID().uuidString)")
    let utc = TimeZone(identifier: "UTC")!

    func make() -> Backfill { Backfill(line: line, transcriber: tr, analyzer: an, store: store, tempDir: dir) }
    let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

    @Test func timesSequence() {
        #expect(Backfill.times(count: 3, now: now, timeZone: utc)
            == ["2023-11-14 22:11", "2023-11-14 22:12", "2023-11-14 22:13"])
        #expect(Backfill.times(count: 1, now: now, timeZone: utc) == ["2023-11-14 22:13"])
    }

    @Test func savesAndNeverMessages() async {
        let out = Box<[String]>([])
        let s = await make().run(ids: ["a"], now: now, timeZone: utc) { out.value.append($0) }
        #expect(s.saved == 1)
        #expect(store.records.value.count == 1)
        #expect(store.records.value[0].time == "2023-11-14 22:13")
        #expect(out.value == ["[a] 已補存 2023-11-14 22:13 家庭生活", "補存 1、略過 0、失敗 0"])
        #expect(line.calls.value == ["download:a"])
        #expect(line.replies.value.isEmpty && line.pushes.value.isEmpty)
    }

    @Test func existingFingerprintSkipsAnalyzer() async {
        store.records.value = [Record(time: "t", fingerprint: Record.fingerprint(of: "你好"),
                                      analysis: Analysis(polished: "", summary: "", sentiment: "", replies: []))]
        let out = Box<[String]>([])
        let s = await make().run(ids: ["a"], now: now, timeZone: utc) { out.value.append($0) }
        #expect(s.skipped == 1 && s.saved == 0)
        #expect(an.count.value == 0)
        #expect(out.value.first == "[a] 已存在，略過")
    }

    @Test func emptyTranscriptSkipped() async {
        tr.result = "  "
        let s = await make().run(ids: ["a"], now: now, timeZone: utc) { _ in }
        #expect(s.skipped == 1)
        #expect(an.count.value == 0 && store.records.value.isEmpty)
    }

    @Test func failureDoesNotStopLaterAndTempCleaned() async {
        an.error = Boom()
        let s1 = await make().run(ids: ["a", "b"], now: now, timeZone: utc) { _ in }
        #expect(s1.failed == 2)
        an.error = nil
        line.downloadError = LineError.notFound
        let s2 = await make().run(ids: ["a"], now: now, timeZone: utc) { _ in }
        #expect(s2.failed == 1)
        line.downloadError = nil
        let s3 = await make().run(ids: ["a"], now: now, timeZone: utc) { _ in }
        #expect(s3.saved == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
    }

    @Test func duplicateTranscriptInBatchAnalyzedOnce() async {
        tr.result = "x"
        _ = await make().run(ids: ["a", "b"], now: now, timeZone: utc) { _ in }
        #expect(an.seenCategories.value.count == 1) // 第二則同指紋 → 已存在
    }
}
