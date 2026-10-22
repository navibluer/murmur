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
    func transcribe(fileURL: URL) async throws -> String {
        files.value.append(fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        return result
    }
}

final class FakeAnalyzer: Analyzer, @unchecked Sendable {
    let count = Box(0)
    var error: Error?
    func analyze(transcript: String) async throws -> Analysis {
        count.value += 1
        if let error { throw error }
        return Analysis(polished: "p", summary: "s", sentiment: "x", replies: ["a"])
    }
}

struct Boom: Error {}

@Suite struct PipelineTests {
    let line = FakeLine()
    let tr = FakeTranscriber()
    let an = FakeAnalyzer()
    let start = ContinuousClock.now
    let offset = Box<Duration>(.zero)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID().uuidString)")

    func make(allowed: Set<String> = ["U1"]) -> Pipeline {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = start, o = offset
        return Pipeline(
            config: Config(lineChannelSecret: "s", lineChannelAccessToken: "t", anthropicAPIKey: "k", allowedUserIDs: allowed),
            line: line, transcriber: tr, analyzer: an, now: { s + o.value }, tempDir: dir)
    }

    func event(id: String = "e1", type: String = "message", source: String = "user", user: String = "U1",
               msg: String = #"{"id":"m1","type":"audio","duration":1000,"contentProvider":{"type":"line"}}"#) throws -> WebhookEvent {
        let json = #"{"type":"\#(type)","webhookEventId":"\#(id)","replyToken":"rt","source":{"type":"\#(source)","userId":"\#(user)"},"deliveryContext":{"isRedelivery":false},"message":\#(msg)}"#
        return try JSONDecoder().decode(WebhookEvent.self, from: Data(json.utf8))
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

    @Test func fileExtensions() {
        #expect(Pipeline.fileExtension(contentType: "audio/mp4") == "m4a")
        #expect(Pipeline.fileExtension(contentType: "audio/aac") == "bin")
        #expect(Pipeline.fileExtension(contentType: nil) == "bin")
    }
}
