import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Reply: Codable, Equatable, Sendable {
    public var label: String
    public var text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

public struct Analysis: Codable, Equatable, Sendable {
    public var polished: String
    public var clean: String
    public var sentiment: String
    public var replies: [Reply]
    public var category: String

    public init(polished: String, clean: String = "", sentiment: String, replies: [Reply], category: String = "") {
        self.polished = polished
        self.clean = clean
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
    let context: String?

    public init(apiKey: String, model: String, session: URLSession = .shared, workspaceID: String? = nil, timeout: TimeInterval = 180,
                context: String? = nil) {
        self.context = context
        self.timeout = timeout
        self.apiKey = apiKey
        self.model = model
        self.workspaceID = workspaceID
        self.session = session
    }

    static let systemPrompt = """
        你是語音訊息分析助手。使用者會提供一段語音轉出的逐字稿（可能有同音錯字、缺標點、口語贅詞）。\
        請呼叫 submit_analysis 工具提交結果，所有欄位一律使用繁體中文（台灣用語），不得出現簡體字。也不要夾雜英文單字（專有名詞除外）。\
        所有欄位需要換行時請直接輸出真正的換行字元，不要輸出跳脫序列（例如反斜線加 n）。

        【欄位定義】
        - polished：潤飾後的逐字稿。修正同音錯字與辨識錯誤、補上標點、分段、去除口語贅詞，但不改變原意、不增刪內容。
        - clean：精簡逐字稿。說話者提到的事實、訴求、問題、數字、日期與時間一個都不能漏；反覆說的話只保留一次；哭訴、哀求、指責、誇張或情緒性的語氣改寫成中性、平靜的敘述；維持說話者的第一人稱；不加入原文沒有的內容，也不加評論。
        - sentiment：情緒分析，包含說話者的情緒與語氣、實際的訴求，以及收訊者需要注意的地方。簡潔、具體。
        - replies：3 則回覆建議，每則是一個物件 { label, text }：
          - label：這則回覆的策略，4～6 個字，例如「簡短收到」「設立界線」「延後處理」「明確拒絕」「表達關心」。3 則必須是不同策略。
          - text：可直接傳送給說話者的訊息，1～3 句，口吻自然，不替使用者做出承諾。
        - category：內容分類，單一簡短的繁體中文詞（2～6 個字）；優先從使用者提供的現有分類中選擇，都不適合時才自訂新分類。

        若下方有【使用者情境】，請依其中的背景、分析重點、回覆原則與名字校正處理；情境中的規則與上方一般規則衝突時，以情境為準。
        除了情境中提供的背景，只依語音內容判斷，不要臆測沒有出現的事實。
        每個欄位都必須是根據逐字稿寫出的完整內容，嚴禁填入 placeholder、空字串或任何佔位文字；只呼叫一次 submit_analysis。
        """

    var systemPrompt: String {
        guard let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.systemPrompt }
        return Self.systemPrompt + "\n\n【使用者情境】\n" + context
    }

    static var tool: [String: Any] { [
        "name": "submit_analysis",
        "description": "提交語音訊息的分析結果",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": [
                "polished": ["type": "string", "description": "潤飾後的逐字稿（繁體中文）；換行請用真正的換行字元，不要輸出跳脫序列"],
                "clean": ["type": "string", "description": "精簡逐字稿：保留所有事實與訴求，去除重複與情緒渲染，改為中性敘述"],
                "sentiment": ["type": "string", "description": "情緒分析（繁體中文）；換行請用真正的換行字元，不要輸出跳脫序列"],
                "replies": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string", "description": "這則回覆的策略標籤（繁體中文，4～6 個字）"],
                            "text": ["type": "string", "description": "可直接傳送的回覆內容（繁體中文）"],
                        ],
                        "required": ["label", "text"],
                        "additionalProperties": false,
                    ] as [String: Any],
                    "description": "3 則回覆建議，每則含策略標籤 label 與可直接傳送的 text",
                ] as [String: Any],
                "category": ["type": "string", "description": "內容分類（繁體中文，2～6 個字）；優先使用現有分類，都不適合時自訂"],
            ],
            "required": ["polished", "clean", "sentiment", "replies", "category"],
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
            "system": systemPrompt,
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
                let cleanText = input["clean"] as? String,
                let sentiment = input["sentiment"] as? String,
                let rawReplies = input["replies"] as? [[String: Any]],
                let category = input["category"] as? String
            else { continue }
            var replies: [Reply] = []
            for r in rawReplies {
                guard let label = r["label"] as? String, let text = r["text"] as? String else { replies = []; break }
                replies.append(Reply(label: clean(label), text: clean(text)))
            }
            let a = Analysis(
                polished: clean(polished), clean: clean(cleanText),
                sentiment: clean(sentiment), replies: replies,
                category: clean(category).trimmingCharacters(in: .whitespacesAndNewlines))
            if Self.isValid(a) { return a }
        }
        return nil
    }

    /// 欄位不可為空白、佔位字樣（placeholder／todo／tbd／n/a）；replies 需 2～4 則，每則 label 與 text 都要合格。
    static func isValid(_ a: Analysis) -> Bool {
        func ok(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty || t.contains("placeholder") { return false }
            return !["todo", "tbd", "n/a"].contains(t)
        }
        return [a.polished, a.clean, a.sentiment, a.category].allSatisfy(ok)
            && (2...4).contains(a.replies.count)
            && a.replies.allSatisfy { ok($0.label) && ok($0.text) }
    }

    /// 模型偶爾會雙重跳脫，解碼後留下字面的反斜線加字母；還原成真正的字元。
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}
