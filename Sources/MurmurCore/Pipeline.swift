import Foundation

public enum DeliveryPolicy {
    public static let budget: Duration = .seconds(50)
    public static func useReply(elapsed: Duration) -> Bool { elapsed < budget }
}

public actor Pipeline {
    enum Copy {
        static let notAudio = "請轉傳語音訊息給我，我會幫你整理逐字稿、重點、情緒與回覆建議。"
        static let external = "這則語音無法下載（外部來源），請改轉傳 LINE 內的語音訊息。"
        static let missing = "找不到這則語音，可能已被收回或過期。"
        static let empty = "沒有辨識到語音內容。"
        static let failed = "處理失敗，請稍後再試。"
        static let analysisFailed = "分析失敗，以下是逐字稿原文："
    }

    private let config: Config
    private let line: LineAPI
    private let transcriber: Transcriber
    private let analyzer: Analyzer
    private let now: @Sendable () -> ContinuousClock.Instant
    private let tempDir: URL
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private let seenLimit = 1000

    public init(config: Config, line: LineAPI, transcriber: Transcriber, analyzer: Analyzer,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                tempDir: URL = FileManager.default.temporaryDirectory) {
        self.config = config
        self.line = line
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.now = now
        self.tempDir = tempDir
    }

    public func handle(_ event: WebhookEvent, receivedAt: ContinuousClock.Instant) async {
        guard event.type == "message", event.source.type == "user", let userId = event.source.userId else { return }
        guard config.allowedUserIDs.contains(userId) else {
            print("未授權的 userId: \(userId)")
            return
        }
        guard markSeen(event.webhookEventId) else { return }

        let token = event.replyToken
        func deliver(_ texts: [String]) async {
            await send(texts, userId: userId, replyToken: token, receivedAt: receivedAt)
        }

        guard let message = event.message, message.type == "audio" else {
            await deliver([Copy.notAudio])
            return
        }
        if message.contentProvider?.type == "external" {
            await deliver([Copy.external])
            return
        }

        do { try await line.startLoading(userId: userId, seconds: 60) }
        catch { print("startLoading 失敗：\(error)") }

        let clock = ContinuousClock()
        var t = clock.now
        func lap(_ name: String) {
            let n = clock.now
            print("[\(message.id)] \(name): \(t.duration(to: n))")
            t = n
        }

        let downloaded: (data: Data, contentType: String?)
        do {
            downloaded = try await line.downloadContent(messageId: message.id)
            lap("download")
        } catch let e as LineError where e == .notFound || e == .gone {
            await deliver([Copy.missing])
            return
        } catch {
            print("下載失敗：\(error)")
            await deliver([Copy.failed])
            return
        }

        let ext = Self.fileExtension(contentType: downloaded.contentType)
        let fileURL = tempDir.appendingPathComponent("\(message.id).\(ext)")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transcript: String
        do {
            try downloaded.data.write(to: fileURL)
            transcript = try await transcriber.transcribe(fileURL: fileURL)
            lap("transcribe")
        } catch {
            print("轉錄失敗：\(error)")
            await deliver([Copy.failed])
            return
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await deliver([Copy.empty])
            return
        }

        let texts: [String]
        do {
            texts = MessageFormatter.format(try await analyzer.analyze(transcript: transcript))
        } catch {
            print("分析失敗：\(error)")
            texts = Self.fallbackTexts(transcript: transcript)
        }
        lap("analyze")

        await deliver(texts)
        lap("send")
    }

    private func markSeen(_ id: String) -> Bool {
        guard !seen.contains(id) else { return false }
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > seenLimit {
            seen.remove(seenOrder.removeFirst())
        }
        return true
    }

    private func send(_ texts: [String], userId: String, replyToken: String?, receivedAt: ContinuousClock.Instant) async {
        if let replyToken, DeliveryPolicy.useReply(elapsed: receivedAt.duration(to: now())) {
            do { try await line.reply(token: replyToken, texts: texts); return }
            catch { print("reply 失敗，改用 push：\(error)") }
        }
        do { try await line.push(to: userId, texts: texts) }
        catch { print("push 失敗：\(error)") }
    }

    static func fileExtension(contentType: String?) -> String {
        let base = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch base {
        case "audio/m4a", "audio/x-m4a", "audio/mp4": return "m4a"
        default: return "bin"
        }
    }

    static func fallbackTexts(transcript: String) -> [String] {
        var chunks: [String] = []
        var cur = ""
        var curLen = 0
        for ch in transcript {
            let l = String(ch).utf16.count
            if curLen + l > MessageFormatter.limit {
                chunks.append(cur)
                cur = ""
                curLen = 0
            }
            cur.append(ch)
            curLen += l
        }
        if !cur.isEmpty { chunks.append(cur) }
        if chunks.count > 4 {
            let last = MessageFormatter.truncate(chunks[3...].joined(), limit: MessageFormatter.limit)
            chunks = Array(chunks.prefix(3)) + [last]
        }
        return [Copy.analysisFailed] + chunks
    }
}
