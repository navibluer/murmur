import Foundation

public enum Hant {
    /// 僅在文字以簡體為主時才轉成繁體；已是繁體（或無法判斷）則原樣回傳，
    /// 避免 Hans-Hant 把「只」之類的共用字誤轉成「隻」。
    public static func convert(_ s: String) -> String {
        let toHans = StringTransform("Hant-Hans")
        let toHant = StringTransform("Hans-Hant")
        var simplified = 0
        var traditional = 0
        for ch in s {
            let c = String(ch)
            let hans = c.applyingTransform(toHans, reverse: false) ?? c
            if hans != c {
                traditional += 1
            } else if (c.applyingTransform(toHant, reverse: false) ?? c) != c {
                simplified += 1
            }
        }
        guard simplified > traditional else { return s }
        return s.applyingTransform(toHant, reverse: false) ?? s
    }
}
