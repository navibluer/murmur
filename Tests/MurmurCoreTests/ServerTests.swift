import CryptoKit
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import MurmurCore

@Suite struct ServerTests {
    let secret = "testsecret"
    let line = FakeLine()
    let tr = FakeTranscriber()
    let an = FakeAnalyzer()

    func app() -> some ApplicationProtocol {
        let config = Config(
            lineChannelSecret: secret, lineChannelAccessToken: "t", anthropicAPIKey: "k", allowedUserIDs: ["U1"])
        let pipeline = Pipeline(config: config, line: line, transcriber: tr, analyzer: an)
        return buildApplication(config: config, pipeline: pipeline)
    }

    func sign(_ body: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }

    let audioEvent = #"{"events":[{"type":"message","webhookEventId":"w1","replyToken":"rt","source":{"type":"user","userId":"U1"},"deliveryContext":{"isRedelivery":false},"message":{"id":"m1","type":"audio","duration":1000,"contentProvider":{"type":"line"}}}]}"#

    @Test func validSignatureEmptyEvents() async throws {
        let body = #"{"events":[]}"#
        try await app().test(.router) { client in
            try await client.execute(
                uri: "/webhook", method: .post, headers: [.init("x-line-signature")!: sign(body)],
                body: ByteBuffer(string: body)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test func missingOrWrongSignature() async throws {
        let body = #"{"events":[]}"#
        try await app().test(.router) { client in
            try await client.execute(uri: "/webhook", method: .post, body: ByteBuffer(string: body)) {
                #expect($0.status == .unauthorized)
            }
            try await client.execute(
                uri: "/webhook", method: .post, headers: [.init("x-line-signature")!: "bogus"],
                body: ByteBuffer(string: body)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test func invalidJSONIs400() async throws {
        let body = "not json"
        try await app().test(.router) { client in
            try await client.execute(
                uri: "/webhook", method: .post, headers: [.init("x-line-signature")!: sign(body)],
                body: ByteBuffer(string: body)
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test func respondsBeforePipelineFinishes() async throws {
        tr.delay = .seconds(1)
        let body = audioEvent
        let clock = ContinuousClock()
        try await app().test(.router) { client in
            let t0 = clock.now
            try await client.execute(
                uri: "/webhook", method: .post, headers: [.init("x-line-signature")!: sign(body)],
                body: ByteBuffer(string: body)
            ) { #expect($0.status == .ok) }
            #expect(clock.now - t0 < .milliseconds(500))
        }
    }

    @Test func health() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) {
                #expect($0.status == .ok)
                #expect(String(buffer: $0.body) == "ok")
            }
        }
    }
}
