import Foundation
import MurmurCore

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "transcribe" else {
    FileHandle.standardError.write(Data("用法：murmur transcribe <音檔>\n".utf8))
    exit(64)
}
let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
let start = Date()
do {
    let text = try await AppleTranscriber().transcribe(fileURL: url)
    print(text)
    let elapsed = Date().timeIntervalSince(start)
    FileHandle.standardError.write(Data(String(format: "transcribe: %.1fs\n", elapsed).utf8))
} catch {
    FileHandle.standardError.write(Data("錯誤：\(error)\n".utf8))
    exit(1)
}
