import Foundation

public enum Hant {
    /// 簡體轉繁體；已是繁體的文字維持不變。
    public static func convert(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s
    }
}
