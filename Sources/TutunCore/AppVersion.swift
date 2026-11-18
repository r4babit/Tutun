import Foundation

/// Сравнение номеров выпусков («v2.10.0» новее «2.9»; недостающие части — нули).
public enum AppVersion {
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            (s.hasPrefix("v") ? String(s.dropFirst()) : s).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
