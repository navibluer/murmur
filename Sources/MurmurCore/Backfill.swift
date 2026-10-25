import Foundation

/// 把功能上線前已處理過的舊語音補存進紀錄：只下載、辨識、分析、寫入，不送任何 LINE 訊息。
public struct Backfill: Sendable {
    public struct Summary: Equatable, Sendable {
        public var saved = 0
        public var skipped = 0
        public var failed = 0
        public init() {}
        public var line: String { "補存 \(saved)、略過 \(skipped)、失敗 \(failed)" }
    }

    private let line: LineAPI
    private let transcriber: Transcriber
    private let analyzer: Analyzer
    private let store: RecordStore
    private let tempDir: URL

    public init(line: LineAPI, transcriber: Transcriber, analyzer: Analyzer, store: RecordStore,
                tempDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-backfill")) {
        self.line = line
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.store = store
        self.tempDir = tempDir
    }

    /// n 個 ID 依序為「now − (n−1−i) 分鐘」，最後一個是 now。
    public static func times(count: Int, now: Date, timeZone: TimeZone = .current) -> [String] {
        (0..<count).map { i in
            let d = now.addingTimeInterval(-Double(count - 1 - i) * 60)
            return Record.formatTime(milliseconds: Int64((d.timeIntervalSince1970 * 1000).rounded()), timeZone: timeZone)
        }
    }

    @discardableResult
    public func run(ids: [String], now: Date = Date(), timeZone: TimeZone = .current,
                    output: (String) -> Void = { print($0) }) async -> Summary {
        var summary = Summary()
        let times = Self.times(count: ids.count, now: now, timeZone: timeZone)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for (id, time) in zip(ids, times) {
            do {
                switch try await process(id: id, time: time) {
                case .saved(let category):
                    summary.saved += 1
                    output("[\(id)] 已補存 \(time) \(category)")
                case .exists:
                    summary.skipped += 1
                    output("[\(id)] 已存在，略過")
                case .empty:
                    summary.skipped += 1
                    output("[\(id)] 逐字稿為空，略過")
                }
            } catch {
                summary.failed += 1
                output("[\(id)] 失敗：\(error)")
            }
        }
        output(summary.line)
        return summary
    }

    private enum Outcome { case saved(String), exists, empty }

    private func process(id: String, time: String) async throws -> Outcome {
        let downloaded = try await line.downloadContent(messageId: id)
        let fileURL = tempDir.appendingPathComponent("\(id).\(Pipeline.fileExtension(contentType: downloaded.contentType))")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transcript: String
        do {
            try downloaded.data.write(to: fileURL)
            transcript = try await transcriber.transcribe(fileURL: fileURL)
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let fingerprint = Record.fingerprint(of: transcript)
        if try store.find(fingerprint: fingerprint) != nil { return .exists }
        let analysis = try await analyzer.analyze(transcript: transcript, categories: store.categories())
        try store.append(Record(time: time, fingerprint: fingerprint, analysis: analysis))
        return .saved(analysis.category)
    }
}
