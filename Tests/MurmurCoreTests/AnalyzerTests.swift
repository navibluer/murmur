import Foundation
import Testing
@testable import MurmurCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

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
        Self.lastRequest = request
        Self.lastBody = body
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AnalyzerTests {
    func makeAnalyzer() -> ClaudeAnalyzer {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return ClaudeAnalyzer(apiKey: "test-key", model: "claude-sonnet-5-5", session: URLSession(configuration: cfg))
    }

    func toolUseResponse(_ input: [String: Any]) -> Data {
        let obj: [String: Any] = [
            "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "tu_1", "name": "submit_analysis", "input": input]],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func sendsExpectedRequestAndParsesAndConvertsToTraditional() async throws {
        StubProtocol.handler = { _, _ in
            (200, self.toolUseResponse([
                "polished": "这是简体中文的逐字稿", "summary": "这是重点", "sentiment": "心情很好",
                "replies": ["好的，没问题", "晚点联系"],
            ]))
        }
        let a = try await makeAnalyzer().analyze(transcript: "原文")
        let req = StubProtocol.lastRequest!
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        // claude-sonnet-5-5 rejects forced tool_choice (400); auto + strict tool is used instead.
        let tc = body["tool_choice"] as! [String: Any]
        #expect(tc["type"] as? String == "auto")
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools[0]["name"] as? String == "submit_analysis")
        #expect(tools[0]["strict"] as? Bool == true)
        #expect(a.polished == "這是簡體中文的逐字稿")
        #expect(a.summary == "這是重點")
        #expect(a.replies.count == 2)
        #expect(a.replies[0] == "好的，沒問題")
    }

    @Test func httpErrorThrows() async {
        StubProtocol.handler = { _, _ in (500, Data("{}".utf8)) }
        await #expect(throws: (any Error).self) {
            _ = try await makeAnalyzer().analyze(transcript: "x")
        }
    }

    @Test func missingToolUseThrowsMalformed() async {
        StubProtocol.handler = { _, _ in
            (200, try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "hi"]], "stop_reason": "end_turn",
            ]))
        }
        await #expect(throws: AnalyzerError.malformedResponse) {
            _ = try await makeAnalyzer().analyze(transcript: "x")
        }
    }
}
