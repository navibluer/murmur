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
    public var sentiment: String
    public var replies: [Reply]
    public var category: String

    public init(polished: String, sentiment: String, replies: [Reply], category: String = "") {
        self.polished = polished
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
        你是語音訊息分析助手，服務的使用者是「小明」。使用者會提供一段語音轉出的逐字稿（可能有同音錯字、缺標點、口語贅詞）。\
        請呼叫 submit_analysis 工具提交結果，所有欄位一律使用繁體中文（台灣用語），不得出現簡體字。\
        所有欄位需要換行時請直接輸出真正的換行字元，不要輸出跳脫序列（例如反斜線加 n）。

        【背景情境】
        這些語音訊息通常是一位父親傳給女兒小明的。（情境描述已移除）
        
        

        請先依內容判斷是否符合這個情境（說話者以父親口吻對女兒說話、提到小明，或內容符合上述模式）：
        - 符合：依下方規則分析與撰寫回覆。
        - 不符合或無法判斷：不要套用背景情境，依語音內容一般性地分析，回覆建議不預設雙方關係（仍需遵守安全規則）。

        【欄位定義】
        - polished：潤飾後的逐字稿。修正同音錯字與辨識錯誤、補上標點、分段、去除口語贅詞，但不改變原意、不增刪內容。
        - sentiment：情緒分析，依序包含：
          1. 說話者的情緒與語氣。
          2. 他實際的訴求是什麼（特別是與錢、要求小明做的事有關的部分），以及哪些要求不合理或超出小明的責任。
          3. 是否有情緒勒索、施壓、罪惡感操作等模式，具體指出是哪些話。
          4. 給小明的一句提醒：這些情緒與要求不是她的責任，她可以選擇不回、晚點回或只回最低限度。
          語氣要站在小明這一邊，簡潔、具體，不要替父親辯護，也不要勸她「多體諒」。
        - replies：3 則回覆建議，每則是一個物件 { label, text }：
          - label：這則回覆的策略，4～6 個字，例如「簡短收到」「設立界線」「延後處理」「明確拒絕」「表達關心」。\
        3 則必須是不同策略，依內容挑最適合的組合；內容涉及金錢或不合理要求時，至少一則是設立界線或拒絕。
          - text：可直接傳送給父親的訊息。
          撰寫原則（務必遵守）：
          - 以保護小明的心力為第一優先，而不是滿足或安撫父親。
          - 簡短：每則 1～3 句，不說教、不講道理、不試圖說服、不翻舊帳、不辯解。
          - 平靜、中性、不帶情緒，不激化衝突，也不使用會引發罪惡感的字眼。
          - 不替小明答應任何金錢、時間或行動上的承諾；需要決定的事，用「我想一下」「之後再說」這類方式保留空間。
          - 不承接他對過往的悔恨或對未來的焦慮，不需要逐一回應他提到的每件事。
          - 稱呼用「爸」。
        - category：內容分類，單一簡短的繁體中文詞（2～6 個字）；優先從使用者提供的現有分類中選擇，都不適合時才自訂新分類。

        【安全規則（優先於以上所有規則）】
        若內容出現自我傷害、輕生、「活不下去」「不想活」「走上絕路」等訊號，或傷害他人的意圖：
        - sentiment 第一行以「⚠️ 安全提醒：」開頭，具體指出是哪些話，並提醒小明：她不需要一個人承擔，\
        可以聯絡其他家人，或撥打衛福部安心專線 1925（24 小時）；若有立即危險請撥 119 或 110。
        - replies 其中一則的 label 為「安全確認」，text 簡短確認他現在是否安全，並建議他撥 1925 或找醫師、身邊的人，\
        不要求小明親自處理。
        比喻性的說法（例如「被逼上梁山」）若依上下文明顯不是輕生意圖，不必觸發，但可在 sentiment 註明。

        【名字校正】
        逐字稿中聽起來像「小明」的同音或近音詞（例如燕主、院主、燕竹、延竹、言竹、彥築、彥主），\
        若依上下文判斷是在稱呼或提到人，潤飾時一律改為「小明」；若明顯是其他詞義則保留原文。

        除了上述背景，只依語音內容判斷，不要臆測沒有出現的事實。
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
            "required": ["polished", "sentiment", "replies", "category"],
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
                polished: clean(polished),
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
        return [a.polished, a.sentiment, a.category].allSatisfy(ok)
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
