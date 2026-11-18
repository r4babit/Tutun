import Foundation

/// Ошибки отдельных соединений ядра sing-box («не удалось соединиться с IP:порт»): тысячи строк с адресами
/// посещённых сайтов, для диагностики службы бесполезны. Служба пишет их в журнал только в режиме «Отладка».
public enum CoreLogFilter {
    public static func isConnectionNoise<S: StringProtocol>(_ line: S) -> Bool {
        let plain = line.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
        // Виды строк: «ERROR[0575] [id 5.0s] connection: …» (без цвета, с --disable-color),
        // «ERROR [id 2ms] connection: …» (с цветом, после удаления кодов), с меткой времени впереди или без.
        return plain.range(of: #"(^|\s)(ERROR|WARN|INFO|DEBUG|TRACE)(\[\d+\])?\s+(\[[^\]]*\]\s+)?connection: "#,
                           options: .regularExpression) != nil
    }
}
