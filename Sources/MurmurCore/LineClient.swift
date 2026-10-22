import Foundation

public protocol LineAPI: Sendable {
    func startLoading(userId: String, seconds: Int) async throws
    func downloadContent(messageId: String) async throws -> (data: Data, contentType: String?)
    func reply(token: String, texts: [String]) async throws
    func push(to userId: String, texts: [String]) async throws
}

public enum LineError: Error, Equatable {
    case notFound, gone, transcodingFailed, transcodingTimeout, tooManyMessages, http(Int)
}

public struct LineClient: LineAPI {
    private let accessToken: String
    private let session: URLSession
    private let pollInterval: Duration
    private let pollLimit: Duration

    public init(accessToken: String, session: URLSession = .shared,
                pollInterval: Duration = .seconds(1), pollLimit: Duration = .seconds(30)) {
        self.accessToken = accessToken
        self.session = session
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
    }

    private static let apiBase = "https://api.line.me/v2/bot"
    private static let dataBase = "https://api-data.line.me/v2/bot"

    private func request(_ url: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LineError.http(-1) }
        return (data, http)
    }

    private func post(_ path: String, json: [String: Any]) async throws {
        let (_, http) = try await send(request(Self.apiBase + path, method: "POST", json: json))
        guard (200..<300).contains(http.statusCode) else { throw LineError.http(http.statusCode) }
    }

    private func messages(_ texts: [String]) throws -> [[String: String]] {
        guard texts.count <= 5 else { throw LineError.tooManyMessages }
        return texts.map { ["type": "text", "text": $0] }
    }

    public func startLoading(userId: String, seconds: Int) async throws {
        try await post("/chat/loading/start", json: ["chatId": userId, "loadingSeconds": seconds])
    }

    public func reply(token: String, texts: [String]) async throws {
        try await post("/message/reply", json: ["replyToken": token, "messages": messages(texts)])
    }

    public func push(to userId: String, texts: [String]) async throws {
        try await post("/message/push", json: ["to": userId, "messages": messages(texts)])
    }

    public func downloadContent(messageId: String) async throws -> (data: Data, contentType: String?) {
        let clock = ContinuousClock()
        let deadline = clock.now + pollLimit
        while true {
            let (data, http) = try await send(request("\(Self.dataBase)/message/\(messageId)/content"))
            switch http.statusCode {
            case 200: return (data, http.value(forHTTPHeaderField: "Content-Type"))
            case 202: break
            case 404: throw LineError.notFound
            case 410: throw LineError.gone
            default: throw LineError.http(http.statusCode)
            }
            // 202：音檔轉碼中，輪詢狀態直到 succeeded
            while true {
                let (sdata, shttp) = try await send(request("\(Self.dataBase)/message/\(messageId)/content/transcoding"))
                guard shttp.statusCode == 200 else { throw LineError.http(shttp.statusCode) }
                let status = (try? JSONSerialization.jsonObject(with: sdata) as? [String: Any])?["status"] as? String
                if status == "succeeded" { break }
                if status == "failed" { throw LineError.transcodingFailed }
                if clock.now >= deadline { throw LineError.transcodingTimeout }
                try await Task.sleep(for: pollInterval)
            }
            if clock.now >= deadline { throw LineError.transcodingTimeout }
        }
    }
}
