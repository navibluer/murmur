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

    @Test func unescapesLiteralBackslashSequences() async throws {
        StubProtocol.handler = { _, _ in
            (200, self.toolUseResponse([
                "polished": "第一段\\n\\n第二段", "summary": "- a\\n- b\\r\\n- c", "sentiment": "好\\t棒\\n真的",
                "replies": ["行一\\n行二"], "category": "家庭生活",
            ]))
        }
        let a = try await makeAnalyzer().analyze(transcript: "原文", categories: ["家庭生活"])
        #expect(a.summary == "- a\n- b\n- c")
        #expect(a.polished == "第一段\n\n第二段")
        #expect(a.sentiment == "好\t棒\n真的")
        #expect(a.replies == ["行一\n行二"])
        for f in [a.polished, a.summary, a.sentiment] + a.replies { #expect(!f.contains("\\")) }
    }

    @Test func sendsExpectedRequestAndParsesAndConvertsToTraditional() async throws {
        StubProtocol.handler = { _, _ in
            (200, self.toolUseResponse([
                "polished": "这是简体中文的逐字稿", "summary": "这是重点", "sentiment": "心情很好",
                "replies": ["好的，没问题", "晚点联系"], "category": " 家庭关系 ",
            ]))
        }
        let a = try await makeAnalyzer().analyze(transcript: "原文", categories: ["家庭生活"])
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
        #expect(a.category == "家庭關係")
        let schema = tools[0]["input_schema"] as! [String: Any]
        #expect((schema["required"] as! [String]).contains("category"))
        #expect((schema["properties"] as! [String: Any])["category"] != nil)
        let msgs = body["messages"] as! [[String: Any]]
        let user = msgs[0]["content"] as! String
        #expect(user.contains("目前分類：家庭生活"))
        #expect(user.contains("2～6 個字"))
        #expect(user.contains("原文"))
        #expect(!(body["system"] as! String).contains("目前分類"))
    }

    @Test func httpErrorThrows() async {
        StubProtocol.handler = { _, _ in (500, Data("{}".utf8)) }
        await #expect(throws: (any Error).self) {
            _ = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        }
    }

    @Test func missingToolUseThrowsMalformed() async {
        StubProtocol.handler = { _, _ in
            (200, try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "hi"]], "stop_reason": "end_turn",
            ]))
        }
        await #expect(throws: AnalyzerError.malformedResponse) {
            _ = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        }
    }

    @Test func maxTokensThrowsTruncated() async {
        StubProtocol.handler = { _, _ in
            (200, try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "cut"]], "stop_reason": "max_tokens",
            ]))
        }
        await #expect(throws: AnalyzerError.truncated) {
            _ = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        }
    }

    @Test func workspaceHeaderSentOnlyWhenSet() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let ok = toolUseResponse(["polished": "a", "summary": "b", "sentiment": "c", "replies": ["d"], "category": "c"])
        StubProtocol.handler = { _, _ in (200, ok) }
        _ = try await ClaudeAnalyzer(apiKey: "k", model: "m", session: URLSession(configuration: cfg), workspaceID: "ws_123").analyze(transcript: "x", categories: ["家庭生活"])
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-workspace-id") == "ws_123")
        _ = try await ClaudeAnalyzer(apiKey: "k", model: "m", session: URLSession(configuration: cfg)).analyze(transcript: "x", categories: ["家庭生活"])
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-workspace-id") == nil)
    }

    func good(_ tag: String = "") -> [String: Any] {
        ["polished": "潤飾\(tag)", "summary": "- 重點", "sentiment": "平穩", "replies": ["好的"], "category": "家庭生活"]
    }
    var bad: [String: Any] { ["polished": "placeholder", "summary": "", "sentiment": "placeholder", "replies": [], "category": "placeholder"] }

    final class Counter: @unchecked Sendable { nonisolated(unsafe) var n = 0 }

    @Test func retriesWhenPlaceholderThenSucceeds() async throws {
        let c = Counter()
        let badData = toolUseResponse(bad), goodData = toolUseResponse(good())
        StubProtocol.handler = { _, _ in c.n += 1; return (200, c.n == 1 ? badData : goodData) }
        let a = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        #expect(c.n == 2)
        #expect(a.polished == "潤飾")
    }

    @Test func picksFirstValidToolUseInSameResponse() async throws {
        let c = Counter()
        let obj: [String: Any] = ["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "1", "name": "submit_analysis", "input": ["polished": "p", "summary": "", "sentiment": "s", "replies": ["r"], "category": "c"]],
            ["type": "tool_use", "id": "2", "name": "submit_analysis", "input": good("二")],
        ]]
        let data = try JSONSerialization.data(withJSONObject: obj)
        StubProtocol.handler = { _, _ in c.n += 1; return (200, data) }
        let a = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        #expect(c.n == 1)
        #expect(a.polished == "潤飾二")
    }

    @Test func throwsInvalidContentAfterThreeAttempts() async {
        let c = Counter()
        let badData = toolUseResponse(bad)
        StubProtocol.handler = { _, _ in c.n += 1; return (200, badData) }
        await #expect(throws: AnalyzerError.invalidContent) {
            _ = try await makeAnalyzer().analyze(transcript: "x", categories: ["家庭生活"])
        }
        #expect(c.n == 3)
    }

    @Test func isValidBoundaries() {
        let ok = Analysis(polished: "a", summary: "b", sentiment: "c", replies: ["d"], category: "e")
        #expect(ClaudeAnalyzer.isValid(ok))
        var x = ok; x.summary = "  \n "; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.polished = "Placeholder"; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.sentiment = "這是 PlaceHolder 文字"; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.category = "TBD"; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.category = " n/a "; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.replies = []; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.replies = ["好", "placeholder"]; #expect(!ClaudeAnalyzer.isValid(x))
        x = ok; x.replies = ["好", " "]; #expect(!ClaudeAnalyzer.isValid(x))
    }
}
