import Foundation

/// Только общие сетевые настройки. Права, автозапуск, HWID и правила приложений сюда не входят.
public struct ConnectionPreferences: Codable, Equatable, Sendable {
    public var mode: ConnectionMode = .tun
    public var routingMode: RoutingMode = .rule
    public var russiaDirect = true
    /// Страна для «Сайты страны — напрямую»; нет поля (старые профили) → "ru".
    public var directCountry: String? = nil
    public var blockAds = false
    public var failover = true
    public var chainServerID: String?
    public var activeProfileID: UUID?
    public var countryPick: CountryPick = .fastest
    public var countryPreferFavorites = true
    public var directDomains: [String] = []
    public var proxyDomains: [String] = []
    public var blockDomains: [String] = []
    public var directIPs: [String] = []
    public var proxyIPs: [String] = []
    public var blockIPs: [String] = []
    public var excludedRoutes: [String] = []
    public var domainStrategy = "IPIfNonMatch"
    public var sniffing = true
    public var ipv6 = false
    public var remoteDNS = "1.1.1.1"
    public var directDNS = "77.88.8.8"
    public var fragment = false
    public var fragmentPackets = "tlshello"
    public var fragmentLength = "100-200"
    public var fragmentInterval = "10-20"
    public var noises = false
    public var mux = false
    public var muxConcurrency = 8
    public var testURL = "https://www.gstatic.com/generate_204"
    public var testTimeout = 5
    public var probeIntervalSec = 30
    public var healthFailLimit = 3

    public init() {}

    public func validate() throws {
        guard (10...300).contains(probeIntervalSec), (1...10).contains(healthFailLimit),
              (2...30).contains(testTimeout), (1...128).contains(muxConcurrency),
              DirectCountry.codes.contains(directCountry ?? "ru"),
              let test = URL(string: testURL), ["http", "https"].contains(test.scheme?.lowercased() ?? ""), test.host?.isEmpty == false else {
            throw ConfigurationProfile.Failure(tr("Некорректные общие сетевые настройки"))
        }
    }
}

/// Общий контракт обмена данными для клиентов macOS, Windows и Android.
/// Не является форматом запуска службы: перед подключением адаптер проверяет возможности платформы.
public struct ConfigurationProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public private(set) var format: String
    public private(set) var schemaVersion: Int
    public var servers: [Server]
    public var subscriptions: [Subscription]
    public var routingProfiles: [RoutingProfile]
    public var preferences: ConnectionPreferences

    public init(servers: [Server] = [], subscriptions: [Subscription] = [], routingProfiles: [RoutingProfile] = [],
                preferences: ConnectionPreferences = .init()) {
        format = "tutun.profile"
        schemaVersion = Self.currentVersion
        self.servers = servers; self.subscriptions = subscriptions
        self.routingProfiles = routingProfiles; self.preferences = preferences
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ text: String) { errorDescription = text }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw Failure(tr("Профиль больше 16 МБ")) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(Self.self, from: data)
        try profile.validate()
        return profile
    }

    public func encode() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 16 * 1024 * 1024 else { throw Failure(tr("Профиль больше 16 МБ")) }
        return data
    }

    public func validate() throws {
        guard format == "tutun.profile", schemaVersion == Self.currentVersion else {
            throw Failure(tr("Неподдерживаемый формат или версия профиля"))
        }
        guard servers.count <= 10_000, Set(servers.map(\.id)).count == servers.count,
              Set(subscriptions.map(\.id)).count == subscriptions.count,
              Set(routingProfiles.map(\.id)).count == routingProfiles.count else {
            throw Failure(tr("Слишком много серверов или повторяются идентификаторы"))
        }
        let subscriptionIDs = Set(subscriptions.map(\.id))
        for server in servers {
            guard !server.id.isEmpty, !server.host.isEmpty, (1...65535).contains(server.port),
                  let outbound = server.outboundJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: outbound)) is [String: Any],
                  server.subscriptionID.map(subscriptionIDs.contains) ?? true else {
                throw Failure(tr("Некорректный сервер или отсутствует связанная подписка"))
            }
        }
        for sub in subscriptions {
            guard let u = URL(string: sub.url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  u.host?.isEmpty == false, (1...168).contains(sub.updateIntervalHours) else {
                throw Failure(tr("Некорректная подписка"))
            }
        }
        try preferences.validate()
        guard preferences.chainServerID.map({ id in servers.contains { $0.id == id } }) ?? true,
              preferences.activeProfileID.map({ id in routingProfiles.contains { $0.id == id } }) ?? true else {
            throw Failure(tr("Некорректные настройки или ссылки на отсутствующие элементы"))
        }
        guard routingProfiles.allSatisfy({ $0.fromSubscription.map(subscriptionIDs.contains) ?? true }) else {
            throw Failure(tr("Отсутствует подписка профиля маршрутов"))
        }
    }
}
