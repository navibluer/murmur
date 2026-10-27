import AVFoundation
import Foundation
import Speech

public protocol Transcriber: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case notAuthorized(String)
    case recognizerUnavailable
    case failed(String)

    public var description: String {
        switch self {
        case .unsupportedLocale(let l): "不支援的語音辨識語系：\(l)"
        case .notAuthorized(let s): "語音辨識未授權：\(s)"
        case .recognizerUnavailable: "SFSpeechRecognizer 不可用"
        case .failed(let m): "語音辨識失敗：\(m)"
        }
    }
}

/// 優先使用 macOS 26 的 SpeechAnalyzer + SpeechTranscriber，不支援時退回 SFSpeechRecognizer。
public struct AppleTranscriber: Transcriber {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "zh-TW")) {
        self.locale = locale
    }

    /// 簡轉繁只在中文語系（identifier 以 zh 開頭）套用。
    static func convertsToTraditional(locale: Locale) -> Bool {
        locale.identifier.lowercased().hasPrefix("zh")
    }

    public func transcribe(fileURL: URL) async throws -> String {
        let raw: String
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            raw = try await transcribeWithAnalyzer(fileURL: fileURL, locale: supported)
        } else {
            raw = try await transcribeWithLegacy(fileURL: fileURL)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.convertsToTraditional(locale: locale) ? Hant.convert(text) : text
    }

    private func transcribeWithAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private func transcribeWithLegacy(fileURL: URL) async throws -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw TranscriberError.notAuthorized("status=\(status.rawValue)")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let box = ResumeOnce(c)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.resume(.success(result.bestTranscription.formattedString))
                } else if let error {
                    box.resume(.failure(TranscriberError.failed(error.localizedDescription)))
                }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String, Error>?
    init(_ c: CheckedContinuation<String, Error>) { cont = c }
    func resume(_ r: Result<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return }
        cont = nil
        c.resume(with: r)
    }
}
