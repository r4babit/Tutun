import Foundation

// Общие модели данных. Системные пути и управление VPN остаются в адаптерах платформ.

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case tun      // весь трафик мака
    case proxy    // системный прокси
}

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case rule     // по правилам
    case global   // всё через VPN
    case direct   // всё напрямую (VPN включён, но ничего не проксирует)
}

public enum AppsMode: String, Codable, CaseIterable, Sendable {
    case exclude  // выбранные приложения мимо VPN
    case include  // только выбранные приложения через VPN
}

public enum PingType: String, Codable, CaseIterable, Sendable {
    case tcp      // время TCP-соединения с сервером
    case url      // настоящий запрос через сервер
}

/// К какому серверу подключаться по клику на страну.
public enum CountryPick: String, Codable, CaseIterable, Sendable {
    case fastest    // самый быстрый из списка, переключение при обрыве
    case lastUsed   // последний выбранный вручную в этой стране
    case first      // первый в списке (по алфавиту)
    case random     // случайный из рабочих
}

public enum ServerSort: String, Codable, CaseIterable, Sendable {
    case ping, name, none
}

/// Какое ядро держит сервер: xray (почти всё) или вспомогательный sing-box (TUIC, Hysteria2 с obfs).
public enum Engine: String, Codable, Sendable { case xray, singbox }

/// Сервер из подписки или добавленный вручную.
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var proto: String
    public var host: String
    public var port: Int
    public var transport: String
    /// Outbound без тега: для xray (engine=xray) или sing-box (engine=singbox).
    public var outboundJSON: String
    public var engine: Engine = .xray
    public var subscriptionID: UUID?
    public var favorite: Bool = false
    /// Исходная ссылка — для копирования, QR и редактирования.
    public var rawLink: String?
    /// Подпись под именем от провайдера (`#Имя?serverDescription=base64`, до 30 символов).
    public var note: String?

    public init(id: String, name: String, proto: String, host: String, port: Int, transport: String,
                outboundJSON: String, engine: Engine = .xray, subscriptionID: UUID? = nil, rawLink: String? = nil) {
        self.id = id; self.name = name; self.proto = proto; self.host = host; self.port = port
        self.transport = transport; self.outboundJSON = outboundJSON; self.engine = engine
        self.subscriptionID = subscriptionID; self.rawLink = rawLink
    }

    enum CodingKeys: String, CodingKey { case id, name, proto, host, port, transport, outboundJSON, engine, subscriptionID, favorite, rawLink, note }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        proto = try c.decode(String.self, forKey: .proto); host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port); transport = try c.decode(String.self, forKey: .transport)
        outboundJSON = try c.decode(String.self, forKey: .outboundJSON)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .xray
        subscriptionID = try c.decodeIfPresent(UUID.self, forKey: .subscriptionID)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        rawLink = try c.decodeIfPresent(String.self, forKey: .rawLink)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public var outbound: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(outboundJSON.utf8))) as? [String: Any] ?? [:]
    }

    /// Флаг страны из начала имени (🇩🇪 …) — для группировки по странам.
    public var flag: String? {
        let scalars = Array(name.unicodeScalars.drop { $0 == " " }.prefix(2))
        guard scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Код страны («SE») из флага.
    public var countryCode: String? {
        guard let f = flag else { return nil }
        return String(f.unicodeScalars.compactMap { UnicodeScalar($0.value - 0x1F1E6 + 65).map(Character.init) })
    }

    public static func countryName(_ code: String) -> String {
        L10n.locale.localizedString(forRegionCode: code) ?? code
    }
}

/// Профиль маршрутов (совместим с форматом happ://routing/add/…).
public struct RoutingProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var directSites: [String] = []
    public var directIPs: [String] = []
    public var proxySites: [String] = []
    public var proxyIPs: [String] = []
    public var blockSites: [String] = []
    public var blockIPs: [String] = []
    public var domainStrategy: String?
    public var remoteDNS: String?
    public var directDNS: String?
    public var geoipURL: String?
    public var geositeURL: String?
    public var globalProxy: Bool = true
    public var fromSubscription: UUID?
    /// Закреплённые адреса (Happ `DnsHosts`): домен → IP, в обход любых DNS.
    public var dnsHosts: [String: String]?
    /// Порядок групп правил (Happ `RouteOrder`), например «block-proxy-direct». nil — этот же порядок.
    public var routeOrder: String?

    public init(name: String) { self.name = name }
}

public struct Subscription: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var url: String
    public var lastUpdate: Date?
    public var lastError: String?
    public var upload: Int64 = 0
    public var download: Int64 = 0
    public var total: Int64 = 0
    public var expire: Date?
    public var announce: String?
    public var supportURL: String?
    public var webPageURL: String?
    public var updateIntervalHours: Int = 12
    public var enabled: Bool = true
    public var collapsed: Bool = false
    // Что ещё сообщает провайдер (заголовки как у INCY/Happ, см. docs/COMPETITORS-2026-11-11.md).
    public var details: String?
    public var supportEmail: String?
    public var announceURL: String?
    /// Профиль маршрутов по ссылке провайдера — обновляется вместе с подпиской.
    public var autoroutingURL: String?
    /// Адреса VPN-серверов узнавать через DoH провайдера (когда DNS интернет-провайдера их подменяет).
    public var serverResolve: ServerResolve?
    /// Фрагментация и шум, которые провайдер просит для своих серверов (если у пользователя они выключены).
    public var providerFragment: ProviderFragment?
    public var providerNoises: ProviderNoises?
    /// Как показывать серверы этой подписки в списке и в каком порядке.
    public var listMode: GroupListMode?
    public var listSort: GroupSort?

    public init(name: String, url: String) { self.name = name; self.url = url }

    enum CodingKeys: String, CodingKey { case id, name, url, lastUpdate, lastError, upload, download, total, expire, announce, supportURL, webPageURL, updateIntervalHours, enabled, collapsed, details, supportEmail, announceURL, autoroutingURL, serverResolve, providerFragment, providerNoises, listMode, listSort }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        lastUpdate = try c.decodeIfPresent(Date.self, forKey: .lastUpdate)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        upload = try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        total = try c.decodeIfPresent(Int64.self, forKey: .total) ?? 0
        expire = try c.decodeIfPresent(Date.self, forKey: .expire)
        announce = try c.decodeIfPresent(String.self, forKey: .announce)
        supportURL = try c.decodeIfPresent(String.self, forKey: .supportURL)
        webPageURL = try c.decodeIfPresent(String.self, forKey: .webPageURL)
        updateIntervalHours = try c.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 12
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        details = try c.decodeIfPresent(String.self, forKey: .details)
        supportEmail = try c.decodeIfPresent(String.self, forKey: .supportEmail)
        announceURL = try c.decodeIfPresent(String.self, forKey: .announceURL)
        autoroutingURL = try c.decodeIfPresent(String.self, forKey: .autoroutingURL)
        serverResolve = try? c.decodeIfPresent(ServerResolve.self, forKey: .serverResolve)
        providerFragment = try? c.decodeIfPresent(ProviderFragment.self, forKey: .providerFragment)
        providerNoises = try? c.decodeIfPresent(ProviderNoises.self, forKey: .providerNoises)
        listMode = try? c.decodeIfPresent(GroupListMode.self, forKey: .listMode)
        listSort = try? c.decodeIfPresent(GroupSort.self, forKey: .listSort)
    }
}

/// Серверы подписки в списке: по странам (по умолчанию) или одним списком.
public enum GroupListMode: String, Codable, Hashable, Sendable, CaseIterable { case countries, list }

/// Порядок внутри подписки: по имени (по умолчанию), по числу серверов в стране, по задержке, как прислал провайдер.
public enum GroupSort: String, Codable, Hashable, Sendable, CaseIterable { case name, count, ping, provider }

/// DoH для адресов VPN-серверов: https-адрес и IP, по которому к нему подключиться (имя DoH-сервера тоже надо знать).
public struct ServerResolve: Codable, Hashable, Sendable {
    public var dohURL: String
    public var bootstrapIP: String
    public init(dohURL: String, bootstrapIP: String) { self.dohURL = dohURL; self.bootstrapIP = bootstrapIP }
}

public struct ProviderFragment: Codable, Hashable, Sendable {
    public var packets: String
    public var length: String
    public var interval: String
    public init(packets: String, length: String, interval: String) { self.packets = packets; self.length = length; self.interval = interval }
}

public struct ProviderNoises: Codable, Hashable, Sendable {
    public var type: String
    public var packet: String
    public var delay: String
    public init(type: String, packet: String, delay: String) { self.type = type; self.packet = packet; self.delay = delay }
}

public struct AppSettings: Codable, Hashable, Sendable {
    // Подключение
    public var mode: ConnectionMode = .tun
    public var killSwitch: Bool = true
    public var autoSelect: Bool = true
    public var selectedServerID: String?
    /// Выбрана страна целиком (код региона, напр. «SE»): самый быстрый сервер этой страны.
    public var selectedCountry: String?
    /// Страны, отмеченные звёздочкой (коды), — в блоке «Избранное» вверху списка.
    public var favoriteCountries: [String] = []
    public var countryPick: CountryPick = .fastest
    /// Если в стране есть серверы со звёздочкой — выбирать только среди них.
    public var countryPreferFavorites: Bool = true
    /// Последний сервер, выбранный вручную в стране: код страны → id сервера.
    public var lastServerByCountry: [String: String] = [:]
    /// При ручном выборе — переключаться на самый быстрый, если выбранный сервер перестал отвечать.
    public var failover: Bool = true
    /// Цепочка: трафик к серверу идёт через этот (первый) сервер.
    public var chainServerID: String?
    public var connectOnLaunch: Bool = false
    public var launchAtLogin: Bool = false
    /// Значок в Dock, пока открыто окно (без него — только значок в строке меню).
    public var showInDock: Bool = true

    // Маршруты
    public var routingMode: RoutingMode = .rule
    public var russiaDirect: Bool = true
    /// Чьи сайты идут напрямую, когда russiaDirect включён: ru, cn, ir, mm, tr, ae (как на Windows). Нет поля → ru.
    public var directCountry: String = "ru"
    public var blockAds: Bool = false
    public var directDomains: [String] = []
    public var proxyDomains: [String] = []
    public var blockDomains: [String] = []
    public var directIPs: [String] = []
    public var proxyIPs: [String] = []
    public var blockIPs: [String] = []
    /// Адреса, которые обходят туннель целиком (не попадают даже в xray).
    public var excludedRoutes: [String] = []
    public var domainStrategy: String = "IPIfNonMatch"
    public var activeProfileID: UUID?
    public var appsMode: AppsMode = .exclude
    public var directApps: [String] = []
    public var includeApps: [String] = []

    // Туннель
    public var sniffing: Bool = true
    public var ipv6: Bool = false
    public var remoteDNS: String = "1.1.1.1"
    public var directDNS: String = "77.88.8.8"
    public var fragment: Bool = false
    public var fragmentPackets: String = "tlshello"
    public var fragmentLength: String = "100-200"
    public var fragmentInterval: String = "10-20"
    public var noises: Bool = false
    /// Параметры шумовых пакетов xray (по умолчанию как раньше; провайдер может прислать свои).
    public var noisesType: String = "rand"
    public var noisesPacket: String = "10-20"
    public var noisesDelay: String = "10-16"
    public var mux: Bool = false
    public var muxConcurrency: Int = 8
    public var logLevel: String = "warning"

    // Локальная сеть
    public var allowLAN: Bool = false
    public var lanSocksPort: Int = 10810
    public var lanHttpPort: Int = 10811
    public var lanUser: String = ""
    public var lanPassword: String = ""

    // Проверка серверов
    public var pingType: PingType = .url
    public var testURL: String = "https://www.gstatic.com/generate_204"
    public var testMethodHead: Bool = false
    public var testTimeout: Int = 5
    public var pingOnLaunch: Bool = true
    public var pingAfterUpdate: Bool = true
    public var sort: ServerSort = .ping

    // Подписки
    public var hwid: String = ""
    public var sendHWID: Bool = false
    /// Разрешить подписки по http:// (по умолчанию только https). ID устройства по http не отправляется никогда.
    public var allowHttpSubscriptions: Bool = false
    public var userAgent: String = ""
    public var subTimeout: Int = 30
    public var ignoreDuplicates: Bool = true
    public var updateSubsOnLaunch: Bool = true
    public var expiryWarnDays: Int = 3

    // Автоматизация
    public var notifications: Bool = true
    public var hotkey: Bool = true
    public var onDemand: Bool = false
    public var trustedSSIDs: [String] = []
    public var geoAutoUpdate: Bool = false
    public var geoipURL: String = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
    public var geositeURL: String = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
    public var geoLastUpdate: Date?

    public var serverRenames: [String: String] = [:]

    // Автопереключение
    public var probeIntervalSec: Int = 30       // как часто проверять связь
    public var healthFailLimit: Int = 3         // сколько неудачных проверок подряд — сервер не отвечает

    public init() {}

    // Терпимое чтение: новые поля получают значения по умолчанию.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        func v<T: Decodable>(_ k: String, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: AnyKey(k))) .flatMap { $0 } ?? cur }
        mode = v("mode", mode); killSwitch = v("killSwitch", killSwitch); autoSelect = v("autoSelect", autoSelect)
        selectedServerID = v("selectedServerID", selectedServerID); selectedCountry = v("selectedCountry", selectedCountry); favoriteCountries = v("favoriteCountries", favoriteCountries); countryPick = v("countryPick", countryPick); countryPreferFavorites = v("countryPreferFavorites", countryPreferFavorites); lastServerByCountry = v("lastServerByCountry", lastServerByCountry); failover = v("failover", failover)
        chainServerID = v("chainServerID", chainServerID); connectOnLaunch = v("connectOnLaunch", connectOnLaunch)
        launchAtLogin = v("launchAtLogin", launchAtLogin); showInDock = v("showInDock", showInDock)
        routingMode = v("routingMode", routingMode); russiaDirect = v("russiaDirect", russiaDirect); directCountry = v("directCountry", directCountry); blockAds = v("blockAds", blockAds)
        directDomains = v("directDomains", directDomains); proxyDomains = v("proxyDomains", proxyDomains); blockDomains = v("blockDomains", blockDomains)
        directIPs = v("directIPs", directIPs); proxyIPs = v("proxyIPs", proxyIPs); blockIPs = v("blockIPs", blockIPs)
        excludedRoutes = v("excludedRoutes", excludedRoutes); domainStrategy = v("domainStrategy", domainStrategy)
        activeProfileID = v("activeProfileID", activeProfileID); appsMode = v("appsMode", appsMode)
        directApps = v("directApps", directApps); includeApps = v("includeApps", includeApps)
        sniffing = v("sniffing", sniffing); ipv6 = v("ipv6", ipv6)
        remoteDNS = v("remoteDNS", v("dnsServer", remoteDNS)); directDNS = v("directDNS", directDNS)
        fragment = v("fragment", fragment); fragmentPackets = v("fragmentPackets", fragmentPackets)
        fragmentLength = v("fragmentLength", fragmentLength); fragmentInterval = v("fragmentInterval", fragmentInterval)
        noises = v("noises", noises); noisesType = v("noisesType", noisesType); noisesPacket = v("noisesPacket", noisesPacket); noisesDelay = v("noisesDelay", noisesDelay); mux = v("mux", mux); muxConcurrency = v("muxConcurrency", muxConcurrency); logLevel = v("logLevel", logLevel)
        allowLAN = v("allowLAN", allowLAN); lanSocksPort = v("lanSocksPort", lanSocksPort); lanHttpPort = v("lanHttpPort", lanHttpPort)
        lanUser = v("lanUser", lanUser); lanPassword = v("lanPassword", lanPassword)
        pingType = v("pingType", pingType); testURL = v("testURL", testURL); testMethodHead = v("testMethodHead", testMethodHead)
        testTimeout = v("testTimeout", testTimeout); pingOnLaunch = v("pingOnLaunch", pingOnLaunch); pingAfterUpdate = v("pingAfterUpdate", pingAfterUpdate)
        sort = v("sort", sort)
        hwid = v("hwid", hwid); sendHWID = v("sendHWID", sendHWID); allowHttpSubscriptions = v("allowHttpSubscriptions", allowHttpSubscriptions); userAgent = v("userAgent", userAgent); subTimeout = v("subTimeout", subTimeout)
        ignoreDuplicates = v("ignoreDuplicates", ignoreDuplicates); updateSubsOnLaunch = v("updateSubsOnLaunch", updateSubsOnLaunch)
        expiryWarnDays = v("expiryWarnDays", expiryWarnDays)
        notifications = v("notifications", notifications); hotkey = v("hotkey", hotkey); onDemand = v("onDemand", onDemand)
        trustedSSIDs = v("trustedSSIDs", trustedSSIDs); geoAutoUpdate = v("geoAutoUpdate", geoAutoUpdate)
        geoipURL = v("geoipURL", geoipURL); geositeURL = v("geositeURL", geositeURL); geoLastUpdate = v("geoLastUpdate", geoLastUpdate)
        serverRenames = v("serverRenames", serverRenames)
        probeIntervalSec = v("probeIntervalSec", probeIntervalSec); healthFailLimit = v("healthFailLimit", healthFailLimit)
    }
}

struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

