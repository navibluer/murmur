import CryptoKit
import Foundation

public enum LineSignature {
    public static func isValid(body: Data, signature: String, secret: String) -> Bool {
        guard let provided = Data(base64Encoded: signature) else { return false }
        let key = SymmetricKey(data: Data(secret.utf8))
        // HMAC.isValidAuthenticationCode 以常數時間比較
        return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: body, using: key)
    }
}
