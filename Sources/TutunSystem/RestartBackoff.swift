import Foundation

/// Пауза между полными пересозданиями ядер, когда связи через серверы нет: сразу, затем через 1, 2, 4, 8 минут,
/// дальше не чаще раза в 10 минут. Без неё при недоступных серверах служба каждые ~50 секунд рвала все соединения,
/// в том числе прямые, и включала аварийную блокировку. Проверки связи в паузе продолжаются, и первая удачная
/// сразу возвращает «Подключено». Сон, смена сети и потеря TUN этой паузой не ограничиваются.
/// Доступ только из очереди службы.
public struct RestartBackoff {
    public private(set) var streak = 0
    public private(set) var nextAllowed = Date.distantPast
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(base: TimeInterval = 60, cap: TimeInterval = 600) {
        self.base = base; self.cap = cap
    }

    /// true — пересоздать можно сейчас; следующая попытка откладывается вдвое дальше прежней.
    public mutating func attempt(now: Date = Date()) -> Bool {
        guard now >= nextAllowed else { return false }
        let delay = min(base * pow(2, Double(min(streak, 16))), cap)
        streak += 1
        nextAllowed = now.addingTimeInterval(delay)
        return true
    }

    /// Связь вернулась, пользователь подключился заново, Mac проснулся или сменилась сеть.
    public mutating func reset() {
        streak = 0
        nextAllowed = .distantPast
    }
}
