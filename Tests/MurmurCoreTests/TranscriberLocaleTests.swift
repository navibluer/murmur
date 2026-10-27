import Foundation
import Testing
@testable import MurmurCore

@Suite struct TranscriberLocaleTests {
    @Test func hantConversionOnlyForChineseLocales() {
        #expect(AppleTranscriber.convertsToTraditional(locale: Locale(identifier: "zh-TW")))
        #expect(AppleTranscriber.convertsToTraditional(locale: Locale(identifier: "zh-HK")))
        #expect(!AppleTranscriber.convertsToTraditional(locale: Locale(identifier: "en-US")))
        #expect(!AppleTranscriber.convertsToTraditional(locale: Locale(identifier: "ja-JP")))
    }
}
