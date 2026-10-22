import Foundation
import Testing
@testable import MurmurCore

final class LineStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        Self.requests.append((request, body))
        let (status, headers, data) = Self.handler?(request, body) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LineClientTests {
    func makeClient(pollLimit: Duration = .seconds(5)) -> LineClient {
        LineStubProtocol.requests = []
        LineStubProtocol.handler = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LineStubProtocol.self]
        return LineClient(accessToken: "tok", session: URLSession(configuration: cfg),
                          pollInterval: .milliseconds(1), pollLimit: pollLimit)
    }

    func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test func downloadReturnsDataAndContentType() async throws {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (200, ["Content-Type": "audio/x-m4a"], Data([1, 2, 3])) }
        let r = try await c.downloadContent(messageId: "M1")
        #expect(r.data == Data([1, 2, 3]))
        #expect(r.contentType == "audio/x-m4a")
        let req = LineStubProtocol.requests[0].0
        #expect(req.url?.absoluteString == "https://api-data.line.me/v2/bot/message/M1/content")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func pollsTranscodingThenDownloads() async throws {
        let c = makeClient()
        nonisolated(unsafe) var contentCalls = 0
        nonisolated(unsafe) var statusCalls = 0
        LineStubProtocol.handler = { req, _ in
            if req.url!.path.hasSuffix("/transcoding") {
                statusCalls += 1
                let s = statusCalls == 1 ? "processing" : "succeeded"
                return (200, [:], Data("{\"status\":\"\(s)\"}".utf8))
            }
            contentCalls += 1
            return contentCalls == 1 ? (202, [:], Data()) : (200, ["Content-Type": "audio/m4a"], Data([9]))
        }
        let r = try await c.downloadContent(messageId: "M1")
        #expect(r.data == Data([9]))
        #expect(statusCalls == 2)
        #expect(LineStubProtocol.requests.contains { $0.0.url?.absoluteString == "https://api-data.line.me/v2/bot/message/M1/content/transcoding" })
    }

    @Test func succeededAfterDeadlineStillDownloads() async throws {
        let c = makeClient(pollLimit: .zero)
        nonisolated(unsafe) var contentCalls = 0
        LineStubProtocol.handler = { req, _ in
            if req.url!.path.hasSuffix("/transcoding") { return (200, [:], Data("{\"status\":\"succeeded\"}".utf8)) }
            contentCalls += 1
            return contentCalls == 1 ? (202, [:], Data()) : (200, ["Content-Type": "audio/m4a"], Data([7]))
        }
        let r = try await c.downloadContent(messageId: "M1")
        #expect(r.data == Data([7]))
    }

    @Test func transcodingFailedThrows() async {
        let c = makeClient()
        LineStubProtocol.handler = { req, _ in
            req.url!.path.hasSuffix("/transcoding") ? (200, [:], Data("{\"status\":\"failed\"}".utf8)) : (202, [:], Data())
        }
        await #expect(throws: LineError.transcodingFailed) { try await c.downloadContent(messageId: "M1") }
    }

    @Test func transcodingTimeoutThrows() async {
        let c = makeClient(pollLimit: .milliseconds(50))
        LineStubProtocol.handler = { req, _ in
            req.url!.path.hasSuffix("/transcoding") ? (200, [:], Data("{\"status\":\"processing\"}".utf8)) : (202, [:], Data())
        }
        await #expect(throws: LineError.transcodingTimeout) { try await c.downloadContent(messageId: "M1") }
    }

    @Test func notFoundAndGone() async {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (404, [:], Data()) }
        await #expect(throws: LineError.notFound) { try await c.downloadContent(messageId: "M1") }
        LineStubProtocol.handler = { _, _ in (410, [:], Data()) }
        await #expect(throws: LineError.gone) { try await c.downloadContent(messageId: "M1") }
        LineStubProtocol.handler = { _, _ in (500, [:], Data()) }
        await #expect(throws: LineError.http(500)) { try await c.downloadContent(messageId: "M1") }
    }

    @Test func replySendsExpectedRequest() async throws {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (200, [:], Data("{}".utf8)) }
        try await c.reply(token: "RT", texts: ["a", "b"])
        let (req, body) = LineStubProtocol.requests[0]
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.line.me/v2/bot/message/reply")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let j = json(body)
        #expect(j["replyToken"] as? String == "RT")
        let msgs = j["messages"] as? [[String: String]]
        #expect(msgs == [["type": "text", "text": "a"], ["type": "text", "text": "b"]])
    }

    @Test func pushSendsExpectedRequest() async throws {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (200, [:], Data("{}".utf8)) }
        try await c.push(to: "U1", texts: ["x"])
        let (req, body) = LineStubProtocol.requests[0]
        #expect(req.url?.absoluteString == "https://api.line.me/v2/bot/message/push")
        let j = json(body)
        #expect(j["to"] as? String == "U1")
        #expect((j["messages"] as? [[String: String]]) == [["type": "text", "text": "x"]])
    }

    @Test func loadingSendsExpectedRequest() async throws {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (202, [:], Data("{}".utf8)) }
        try await c.startLoading(userId: "U1", seconds: 60)
        let (req, body) = LineStubProtocol.requests[0]
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.line.me/v2/bot/chat/loading/start")
        let j = json(body)
        #expect(j["chatId"] as? String == "U1")
        #expect(j["loadingSeconds"] as? Int == 60)
    }

    @Test func nonSuccessMapsToHttpError() async {
        let c = makeClient()
        LineStubProtocol.handler = { _, _ in (400, [:], Data()) }
        await #expect(throws: LineError.http(400)) { try await c.reply(token: "RT", texts: ["a"]) }
        await #expect(throws: LineError.http(400)) { try await c.push(to: "U", texts: ["a"]) }
        await #expect(throws: LineError.http(400)) { try await c.startLoading(userId: "U", seconds: 5) }
    }

    @Test func tooManyMessagesThrowsBeforeRequest() async {
        let c = makeClient()
        let six = Array(repeating: "t", count: 6)
        await #expect(throws: LineError.tooManyMessages) { try await c.reply(token: "RT", texts: six) }
        await #expect(throws: LineError.tooManyMessages) { try await c.push(to: "U", texts: six) }
        #expect(LineStubProtocol.requests.isEmpty)
    }
}
