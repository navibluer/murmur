import Foundation
import Testing
@testable import MurmurCore

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); defer { lock.unlock() }; v = newValue }
    }
}

final class FakeLine: LineAPI, @unchecked Sendable {
    let calls = Box<[String]>([])
    let replies = Box<[[String]]>([])
    let pushes = Box<[[String]]>([])
    var downloadError: Error?
    var replyError: Error?
    var loadingError: Error?
    var audio = (data: Data("abc".utf8), contentType: Optional("audio/x-m4a"))

    func startLoading(userId: String, seconds: Int) async throws {
        calls.value.append("loading:\(userId):\(seconds)")
        if let loadingError { throw loadingError }
    }
    func downloadContent(messageId: String) async throws -> (data: Data, contentType: String?) {
        calls.value.append("download:\(messageId)")
        if let downloadError { throw downloadError }
        return audio
    }
    func reply(token: String, texts: [String]) async throws {
        calls.value.append("reply:\(token)")
        if let replyError { throw replyError }
        replies.value.append(texts)
    }
    func push(to userId: String, texts: [String]) async throws {
        calls.value.append("push:\(userId)")
        pushes.value.append(texts)
    }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    let files = Box<[URL]>([])
    var result = "你好"
    var delay: Duration?
    let inFlight = Box(0)
    let maxInFlight = Box(0)
    func transcribe(fileURL: URL) async throws -> String {
        inFlight.value += 1
        maxInFlight.value = max(maxInFlight.value, inFlight.value)
        defer { inFlight.value -= 1 }
        if let delay { try await Task.sleep(for: delay) }
        files.value.append(fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        return result
    }
}

final class FakeAnalyzer: Analyzer, @unchecked Sendable {
    let count = Box(0)
    var error: Error?
    let seenCategories = Box<[[String]]>([])
    func analyze(transcript: String, categories: [String]) async throws -> Analysis {
        count.value += 1
        seenCategories.value.append(categories)
        if let error { throw error }
        return Analysis(polished: "p", summary: "s", sentiment: "x", replies: ["a"], category: "家庭生活")
    }
}

final class FakeStore: RecordStore, @unchecked Sendable {
    let records = Box<[Record]>([])
    var cats = ["家庭生活", "自訂"]
    var appendError: Error?
    var findError: Error?
    func categories() throws -> [String] { cats }
    func find(fingerprint: String) throws -> Record? {
        if let findError { throw findError }
        return records.value.first { $0.fingerprint == fingerprint }
    }
    func append(_ r: Record) throws {
        if let appendError { throw appendError }
        records.value.append(r)
    }
}

struct Boom: Error {}

@Suite struct PipelineTests {
    let line = FakeLine()
    let tr = FakeTranscriber()
    let an = FakeAnalyzer()
    let store = FakeStore()
    let start = ContinuousClock.now
    let offset = Box<Duration>(.zero)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID().uuidString)")

    func make(allowed: Set<String> = ["U1"]) -> Pipeline {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = start, o = offset
        return Pipeline(
            config: Config(lineChannelSecret: "s", lineChannelAccessToken: "t", anthropicAPIKey: "k", allowedUserIDs: allowed),
            line: line, transcriber: tr, analyzer: an, store: store, now: { s + o.value }, tempDir: dir)
    }

    func event(id: String = "e1", type: String = "message", source: String = "user", user: String = "U1",
               msg: String = #"{"id":"m1","type":"audio","duration":1000,"contentProvider":{"type":"line"}}"#) throws -> WebhookEvent {
        let json = #"{"type":"\#(type)","webhookEventId":"\#(id)","replyToken":"rt","source":{"type":"\#(source)","userId":"\#(user)"},"deliveryContext":{"isRedelivery":false},"timestamp":1692251666727,"message":\#(msg)}"#
        return try JSONDecoder().decode(WebhookEvent.self, from: Data(json.utf8))
    }

    @Test func staleAudioClearedOnInit() throws {
        let sub = dir.appendingPathComponent("murmur-audio")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let stale = sub.appendingPathComponent("old.m4a")
        try Data("x".utf8).write(to: stale)
        _ = make()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: sub.path))
    }

    @Test func serialProcessing() async throws {
        tr.delay = .milliseconds(50)
        let p = make()
        let e1 = try event(id: "a", msg: #"{"id":"m1","type":"audio","contentProvider":{"type":"line"}}"#)
        let e2 = try event(id: "b", msg: #"{"id":"m2","type":"audio","contentProvider":{"type":"line"}}"#)
        let s = start
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await p.handle(e1, receivedAt: s) }
            g.addTask { await p.handle(e2, receivedAt: s) }
        }
        #expect(tr.maxInFlight.value == 1)
        #expect(tr.files.value.count == 2)
        #expect(line.replies.value.count == 2)
    }

    @Test func noReplyTokenPushes() async throws {
        let json = #"{"type":"message","webhookEventId":"n1","source":{"type":"user","userId":"U1"},"deliveryContext":{"isRedelivery":false},"message":{"id":"m1","type":"audio","contentProvider":{"type":"line"}}}"#
        let e = try JSONDecoder().decode(WebhookEvent.self, from: Data(json.utf8))
        let p = make()
        await p.handle(e, receivedAt: start)
        #expect(line.replies.value.isEmpty)
        #expect(line.pushes.value.count == 1 && line.pushes.value[0].count == 4)
    }

    @Test func policy() {
        #expect(DeliveryPolicy.useReply(elapsed: .seconds(49)))
        #expect(!DeliveryPolicy.useReply(elapsed: .seconds(50)))
    }

    @Test func notWhitelisted() async throws {
        let p = make()
        await p.handle(try event(user: "U9"), receivedAt: start)
        #expect(line.calls.value.isEmpty && tr.files.value.isEmpty && an.count.value == 0)
    }

    @Test func emptyWhitelist() async throws {
        let p = make(allowed: [])
        await p.handle(try event(), receivedAt: start)
        #expect(line.calls.value.isEmpty && an.count.value == 0)
    }

    @Test func groupIgnored() async throws {
        let p = make()
        await p.handle(try event(source: "group"), receivedAt: start)
        #expect(line.calls.value.isEmpty)
    }

    @Test func dedupe() async throws {
        let p = make()
        await p.handle(try event(), receivedAt: start)
        let n = line.calls.value.count
        await p.handle(try event(), receivedAt: start)
        #expect(line.calls.value.count == n)
        #expect(an.count.value == 1)
    }

    @Test func textMessage() async throws {
        let p = make()
        await p.handle(try event(msg: #"{"id":"m","type":"text","text":"hi"}"#), receivedAt: start)
        #expect(line.replies.value == [["請轉傳語音訊息給我，我會幫你整理逐字稿、重點、情緒與回覆建議。"]])
    }

    @Test func audioReply() async throws {
        let p = make()
        offset.value = .seconds(10)
        await p.handle(try event(), receivedAt: start)
        #expect(line.calls.value.first == "loading:U1:60")
        #expect(line.replies.value.count == 1 && line.replies.value[0].count == 4)
        #expect(line.pushes.value.isEmpty)
        let f = try #require(tr.files.value.first)
        #expect(f.lastPathComponent == "m1.m4a")
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func audioPushWhenLate() async throws {
        let p = make()
        offset.value = .seconds(55)
        await p.handle(try event(), receivedAt: start)
        #expect(line.pushes.value.count == 1 && line.pushes.value[0].count == 4)
        #expect(line.replies.value.isEmpty)
        #expect(!line.calls.value.contains { $0.hasPrefix("reply") })
    }

    @Test func replyFailureFallsBackToPush() async throws {
        line.replyError = LineError.http(400)
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.pushes.value.count == 1)
    }

    @Test func loadingFailureContinues() async throws {
        line.loadingError = Boom()
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.replies.value.first?.count == 4)
    }

    @Test func external() async throws {
        let p = make()
        await p.handle(try event(msg: #"{"id":"m","type":"audio","contentProvider":{"type":"external"}}"#), receivedAt: start)
        #expect(line.replies.value == [["這則語音無法下載（外部來源），請改轉傳 LINE 內的語音訊息。"]])
        #expect(!line.calls.value.contains { $0.hasPrefix("download") })
    }

    @Test func gone() async throws {
        line.downloadError = LineError.gone
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.replies.value == [["找不到這則語音，可能已被收回或過期。"]])
    }

    @Test func otherDownloadError() async throws {
        line.downloadError = LineError.http(500)
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.replies.value == [["處理失敗，請稍後再試。"]])
    }

    @Test func emptyTranscript() async throws {
        tr.result = "  "
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.replies.value == [["沒有辨識到語音內容。"]])
        #expect(an.count.value == 0)
    }

    @Test func analyzerFailureFallback() async throws {
        tr.result = String(repeating: "字", count: 22_000)
        an.error = Boom()
        let p = make()
        await p.handle(try event(), receivedAt: start)
        let msgs = try #require(line.replies.value.first)
        #expect(msgs[0] == "分析失敗，以下是逐字稿原文：")
        #expect(msgs.count == 5)
        #expect(msgs.allSatisfy { $0.utf16.count <= 5000 })
        #expect(msgs[4].hasSuffix("（已截斷）"))
    }

    @Test func fallbackShortTranscript() {
        let t = Pipeline.fallbackTexts(transcript: "短")
        #expect(t == ["分析失敗，以下是逐字稿原文：", "短"])
    }

    @Test func normalPathAppendsRecord() async throws {
        let p = make()
        await p.handle(try event(), receivedAt: start)
        let r = try #require(store.records.value.first)
        #expect(store.records.value.count == 1)
        #expect(r.fingerprint == Record.fingerprint(of: "你好"))
        #expect(r.analysis.category == "家庭生活")
        #expect(r.time == Record.formatTime(milliseconds: 1_692_251_666_727))
        #expect(an.seenCategories.value == [["家庭生活", "自訂"]])
    }

    @Test func duplicateFingerprintSkipsAnalyzerButReplies() async throws {
        let cached = Analysis(polished: "舊逐字稿", summary: "舊重點", sentiment: "舊", replies: ["舊回覆"], category: "舊分類")
        store.records.value = [Record(time: "2020-01-01 00:00", fingerprint: Record.fingerprint(of: "你好"), analysis: cached)]
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(an.count.value == 0)
        #expect(store.records.value.count == 1)
        let msgs = try #require(line.replies.value.first)
        #expect(msgs.count == 4)
        #expect(msgs[0].contains("🏷️ 分類：舊分類") && msgs[0].contains("舊重點"))
    }

    @Test func storeAppendFailureStillReplies() async throws {
        store.appendError = Boom()
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(line.replies.value.first?.count == 4)
    }

    @Test func storeReadFailureTreatedAsMissingWithSeedCategories() async throws {
        store.findError = Boom()
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(an.count.value == 1)
        #expect(line.replies.value.first?.count == 4)
    }

    @Test func analyzerFailureWritesNoRecord() async throws {
        an.error = Boom()
        let p = make()
        await p.handle(try event(), receivedAt: start)
        #expect(store.records.value.isEmpty)
        #expect(line.replies.value.first?[0] == "分析失敗，以下是逐字稿原文：")
    }

    @Test func fileExtensions() {
        #expect(Pipeline.fileExtension(contentType: "audio/mp4") == "m4a")
        #expect(Pipeline.fileExtension(contentType: "audio/aac") == "bin")
        #expect(Pipeline.fileExtension(contentType: nil) == "bin")
    }
}
