import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Analysis: Codable, Equatable, Sendable {
    public var polished: String
    public var summary: String
    public var sentiment: String
    public var replies: [String]
    public var category: String

    public init(polished: String, summary: String, sentiment: String, replies: [String], category: String = "") {
        self.polished = polished
        self.summary = summary
        self.sentiment = sentiment
        self.replies = replies
        self.category = category
    }
}

public enum AnalyzerError: Error, Equatable {
    case malformedResponse
    case truncated
    case invalidContent
    case http(status: Int, body: String)
}

public protocol Analyzer: Sendable {
    func analyze(transcript: String, categories: [String]) async throws -> Analysis
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
        所有欄位需要換行時請直接輸出真正的換行字元，不要輸出跳脫序列（例如反斜線加 n）。
        - replies：2 到 3 則回覆建議（字串陣列），口吻自然，可直接傳送給對方。
        - category：內容分類，單一簡短的繁體中文詞（2～6 個字）；優先從使用者提供的現有分類中選擇，都不適合時才自訂新分類。
        常見情境：這通常是「爸爸」傳給「小明」的語音訊息，使用者就是小明。請先依內容判斷是否符合這個情境\
        （例如說話者以長輩、父親的口吻對子女說話，或提到小明）：
        - 符合：回覆建議以小明回覆爸爸的身分與口吻撰寫；情緒分析可從父親對子女的角度解讀。
        - 不符合或無法判斷：不要套用這個情境，依語音內容一般性地分析，回覆建議不預設雙方關係。
        名字校正：逐字稿中聽起來像「小明」的同音或近音詞（例如燕主、院主、燕竹、延竹、言竹、彥築），\
        若依上下文判斷是在稱呼或提到人，潤飾時一律改為「小明」；若明顯是其他詞義則保留原文。
        除此之外，只依語音內容判斷，不要臆測沒有出現的脈絡。
        每個欄位都必須是根據逐字稿寫出的完整內容，嚴禁填入 placeholder、空字串或任何佔位文字；只呼叫一次 submit_analysis。
        """

    static var tool: [String: Any] { [
        "name": "submit_analysis",
        "description": "提交語音訊息的分析結果",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": [
                "polished": ["type": "string", "description": "潤飾後的逐字稿（繁體中文）；換行請用真正的換行字元，不要輸出跳脫序列"],
                "summary": ["type": "string", "description": "條列式重點整理（繁體中文）；換行請用真正的換行字元，不要輸出跳脫序列"],
                "sentiment": ["type": "string", "description": "情緒分析（繁體中文）；換行請用真正的換行字元，不要輸出跳脫序列"],
                "replies": ["type": "array", "items": ["type": "string"], "description": "2～3 則回覆建議（繁體中文）"],
                "category": ["type": "string", "description": "內容分類（繁體中文，2～6 個字）；優先使用現有分類，都不適合時自訂"],
            ],
            "required": ["polished", "summary", "sentiment", "replies", "category"],
            "additionalProperties": false,
        ] as [String: Any],
    ] }

    public func analyze(transcript: String, categories: [String]) async throws -> Analysis {
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
                "content": "目前分類：\(categories.joined(separator: "、"))。請從中選一個最符合的；都不適合時，自訂一個新的簡短分類（2～6 個字，繁體中文）。\n\n請對以下逐字稿呼叫 submit_analysis 提交分析：\n\n\(transcript)",
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 1...Self.maxAttempts {
            if let result = try await attemptOnce(req) { return result }
            if attempt < Self.maxAttempts { print("分析結果不完整（第 \(attempt) 次），重試") }
        }
        throw AnalyzerError.invalidContent
    }

    static let maxAttempts = 3

    /// 回傳 nil 代表內容不合格（需重試）；其餘錯誤維持原行為直接丟出。
    private func attemptOnce(_ req: URLRequest) async throws -> Analysis? {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AnalyzerError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AnalyzerError.http(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if parsed?["stop_reason"] as? String == "max_tokens" { throw AnalyzerError.truncated }
        guard let root = parsed, let content = root["content"] as? [[String: Any]] else { throw AnalyzerError.malformedResponse }
        let blocks = content.filter { $0["type"] as? String == "tool_use" && $0["name"] as? String == "submit_analysis" }
        guard !blocks.isEmpty else { throw AnalyzerError.malformedResponse }

        func clean(_ s: String) -> String { Hant.convert(Self.unescape(s)) }
        for block in blocks {
            guard let input = block["input"] as? [String: Any],
                let polished = input["polished"] as? String,
                let summary = input["summary"] as? String,
                let sentiment = input["sentiment"] as? String,
                let replies = input["replies"] as? [String],
                let category = input["category"] as? String
            else { continue }
            let a = Analysis(
                polished: clean(polished), summary: clean(summary),
                sentiment: clean(sentiment), replies: replies.map(clean),
                category: clean(category).trimmingCharacters(in: .whitespacesAndNewlines))
            if Self.isValid(a) { return a }
        }
        return nil
    }

    /// 欄位不可為空白、佔位字樣（placeholder／todo／tbd／n/a）；replies 至少一則且每則都要合格。
    static func isValid(_ a: Analysis) -> Bool {
        func ok(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty || t.contains("placeholder") { return false }
            return !["todo", "tbd", "n/a"].contains(t)
        }
        return [a.polished, a.summary, a.sentiment, a.category].allSatisfy(ok)
            && !a.replies.isEmpty && a.replies.allSatisfy(ok)
    }

    /// 模型偶爾會雙重跳脫，解碼後留下字面的反斜線加字母；還原成真正的字元。
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}
