import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

@Suite struct LineSignatureTests {
    let secret = "testsecret"
    let body = Data(#"{"events":[]}"#.utf8)

    func sign(_ data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }

    @Test func valid() {
        #expect(LineSignature.isValid(body: body, signature: sign(body), secret: secret))
    }

    @Test func tamperedBody() {
        let sig = sign(body)
        let bad = Data(#"{"events":[1]}"#.utf8)
        #expect(!LineSignature.isValid(body: bad, signature: sig, secret: secret))
    }

    @Test func nonBase64() {
        #expect(!LineSignature.isValid(body: body, signature: "!!!not base64!!!", secret: secret))
    }
}
