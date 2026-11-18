import Foundation
import TutunShared

/// Пути, общие для приложения и службы.
public enum Paths {
    public static let installDir = "/Library/Application Support/Tutun"
    public static let binDir = installDir + "/bin"
    public static let xray = binDir + "/xray"
    public static let singBox = binDir + "/sing-box"
    /// Сброс прав до nobody перед запуском ядер с конфигами от провайдера (см. tutund/unprivileged).
    public static let dropper = binDir + "/tutun-drop"
    public static let daemonState = installDir + "/state.json"
    public static let runDir = installDir + "/run"
    public static let socket = "/var/run/tutun.sock"
    public static let log = "/var/log/tutun.log"
    public static let daemonLabel = "local.tutun.daemon"
    public static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"

    /// Внутренние порты (только 127.0.0.1).
    public static let socksPort = 10808
    /// Вход только для проверки связи и IP: всегда идёт через выбранный сервер, мимо правил маршрутов
    /// (иначе с профилем «остальное напрямую» проверка шла бы мимо сервера и не замечала его отказа).
    public static let healthPort = 10807
    public static let httpPort = 10809
    public static let apiPort = 10085
    public static let clashPort = 9095
    /// Порты вспомогательного sing-box для Hysteria2-obfs и TUIC: 20000 + номер.
    public static let helperBasePort = 20000
    /// Пробные входы: 21000 + номер кандидата → служба замеряет каждый сервер отдельно.
    public static let probeBasePort = 21000

    /// Ядра внутри Tutun.app — для проверки серверов от имени пользователя.
    public static var bundledXray: String { (Bundle.main.resourcePath ?? "") + "/xray" }
    public static var bundledSingBox: String { (Bundle.main.resourcePath ?? "") + "/sing-box" }
}

// Совместимость существующих macOS-модулей после выделения общего пакета.
public typealias ConnectionMode = TutunShared.ConnectionMode
public typealias RoutingMode = TutunShared.RoutingMode
public typealias AppsMode = TutunShared.AppsMode
public typealias PingType = TutunShared.PingType
public typealias CountryPick = TutunShared.CountryPick
public typealias ServerSort = TutunShared.ServerSort
public typealias Engine = TutunShared.Engine
public typealias Server = TutunShared.Server
public typealias RoutingProfile = TutunShared.RoutingProfile
public typealias Subscription = TutunShared.Subscription
public typealias AppSettings = TutunShared.AppSettings

/// Как служба держит связь: проверка раз в intervalSec; failLimit неудач подряд — сервер не отвечает.
/// Если кандидатов несколько (p0…pN), служба остаётся на текущем, пока он отвечает, а при обрыве
/// переходит на самый быстрый из отвечающих. Скорость сама по себе переключения не вызывает.
public struct SelectorParams: Codable, Sendable, Equatable {
    public var candidates: Int
    public var intervalSec: Int
    public var failLimit: Int
    public var testURL: String
    public var timeoutSec: Int
    public init(candidates: Int, intervalSec: Int, failLimit: Int, testURL: String, timeoutSec: Int) {
        self.candidates = candidates; self.intervalSec = intervalSec; self.failLimit = failLimit
        self.testURL = testURL; self.timeoutSec = timeoutSec
    }
}

/// Запрос к службе.
public struct DaemonRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case status, start, stop, ping, updateGeo }
    public var cmd: Command
    public var mode: ConnectionMode?
    public var killSwitch: Bool?
    public var xrayConfig: String?
    /// Root-служба сама собирает конфиги из проверенного описания подключения.
    public var connection: ConfigBuilder.Input?
    public var singBoxConfig: String?
    /// Вспомогательный sing-box (TUIC, Hysteria2 с obfs) — локальные socks-порты для xray.
    public var helperConfig: String?
    public var serverLabel: String?
    public var selector: SelectorParams?
    public var geoipURL: String?
    public var geositeURL: String?

    public init(cmd: Command) { self.cmd = cmd }
}

public enum TunnelState: String, Codable, Sendable {
    case stopped, starting, running, reconnecting, failed
}

public struct GeoUpdateProgress: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case downloading, checking, installing }
    public var stage: Stage
    public var file: String?
    public var bytes: Int64 = 0
    public var total: Int64?

    public init(stage: Stage, file: String? = nil) {
        self.stage = stage
        self.file = file
    }
}

public struct DaemonStatus: Codable, Sendable {
    public var ok: Bool = true
    public var error: String?
    public var info: String?
    public var state: TunnelState = .stopped
    public var mode: ConnectionMode?
    public var serverLabel: String?
    public var activeOutbound: String?
    public var since: Date?
    public var uplink: Int64 = 0
    public var downlink: Int64 = 0
    public var restarts: Int = 0
    public var healthy: Bool?
    public var latencyMs: Int?
    public var killSwitch: Bool?
    /// Интернет сейчас закрыт блокировкой: VPN включён, но туннель не работает (подключение, восстановление, ошибка).
    public var blocking: Bool?
    public var version: String = DaemonStatus.daemonVersion
    public var geoProgress: GeoUpdateProgress?
    public var log: [String] = []

    public static let statusChangedNotification = "local.tutun.daemon.status-changed"
    public static let daemonVersion = "2.18"
    public init() {}
}

public extension JSONEncoder {
    static var tunnel: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
}
public extension JSONDecoder {
    static var tunnel: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
