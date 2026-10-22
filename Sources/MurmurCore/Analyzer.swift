import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Analysis: Codable, Equatable, Sendable {
    public var polished: String
    public var summary: String
    public var sentiment: String
    public var replies: [String]

    public init(polished: String, summary: String, sentiment: String, replies: [String]) {
        self.polished = polished
        self.summary = summary
        self.sentiment = sentiment
        self.replies = replies
    }
}

public enum AnalyzerError: Error, Equatable {
    case malformedResponse
    case truncated
    case http(status: Int, body: String)
}

public protocol Analyzer: Sendable {
    func analyze(transcript: String) async throws -> Analysis
}

public struct ClaudeAnalyzer: Analyzer {
    let apiKey: String
    let model: String
    let session: URLSession
    let workspaceID: String?
    let timeout: TimeInterval

    public init(apiKey: String, model: String, session: URLSession = .shared, workspaceID: String? = nil, timeout: TimeInterval = 180) {
        self.timeout = timeout
        self.apiKey = apiKey
        self.model = model
        self.workspaceID = workspaceID
        self.session = session
    }

    static let systemPrompt = """
        你是語音訊息分析助手。使用者會提供一段語音轉出的逐字稿（可能有同音錯字、缺標點、口語贅詞）。\
        請呼叫 submit_analysis 工具提交結果，所有欄位一律使用繁體中文（台灣用語），不得出現簡體字。欄位定義：
        - polished：潤飾後的逐字稿。修正同音錯字與辨識錯誤、補上標點、分段、去除口語贅詞，但不改變原意、不增刪內容。
        - summary：重點整理，以條列呈現（每行以「- 」開頭）。
        - sentiment：情緒分析，包含整體情緒、語氣，以及需要注意的地方。
        - replies：2 到 3 則回覆建議（字串陣列），口吻自然，可直接傳送給對方。
        只依語音內容判斷，不要臆測沒有出現的脈絡。
        """

    static var tool: [String: Any] { [
        "name": "submit_analysis",
        "description": "提交語音訊息的分析結果",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": [
                "polished": ["type": "string", "description": "潤飾後的逐字稿（繁體中文）"],
                "summary": ["type": "string", "description": "條列式重點整理（繁體中文）"],
                "sentiment": ["type": "string", "description": "情緒分析（繁體中文）"],
                "replies": ["type": "array", "items": ["type": "string"], "description": "2～3 則回覆建議（繁體中文）"],
            ],
            "required": ["polished", "summary", "sentiment", "replies"],
            "additionalProperties": false,
        ] as [String: Any],
    ] }

    public func analyze(transcript: String) async throws -> Analysis {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let workspaceID, !workspaceID.isEmpty { req.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id") }
        // claude-sonnet-5-5 rejects forced tool_choice (400), so use auto + strict tool + prompt instruction.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Self.systemPrompt,
            "tools": [Self.tool],
            "tool_choice": ["type": "auto"],
            "messages": [[
                "role": "user",
                "content": "請對以下逐字稿呼叫 submit_analysis 提交分析：\n\n\(transcript)",
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AnalyzerError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AnalyzerError.http(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if parsed?["stop_reason"] as? String == "max_tokens" { throw AnalyzerError.truncated }
        guard let root = parsed,
            let content = root["content"] as? [[String: Any]],
            let block = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "submit_analysis" }),
            let input = block["input"] as? [String: Any],
            let polished = input["polished"] as? String,
            let summary = input["summary"] as? String,
            let sentiment = input["sentiment"] as? String,
            let replies = input["replies"] as? [String]
        else { throw AnalyzerError.malformedResponse }

        return Analysis(
            polished: Hant.convert(polished), summary: Hant.convert(summary),
            sentiment: Hant.convert(sentiment), replies: replies.map(Hant.convert))
    }
}
