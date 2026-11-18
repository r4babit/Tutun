import Foundation
import TutunShared

/// Готовый набор конфигов для службы.
public struct BuiltConfig: Sendable {
    public var xray: String
    public var singBox: String?
    public var helper: String?
    /// p0, p1, … → сервер.
    public var servers: [Server]
}

/// Собирает конфиги xray (выбор сервера, маршруты), sing-box (перехват трафика мака)
/// и вспомогательного sing-box (TUIC, Hysteria2 с obfs).
public enum ConfigBuilder {
    public struct Input: Codable, Sendable {
        public var servers: [Server]          // p0…pN; при ручном выборе с подстраховкой p0 — выбранный
        public var settings: AppSettings
        public var profile: RoutingProfile?
        public var chain: Server?             // первый узел цепочки
        /// Ручной выбор + запасной сервер. Конфиг от этого не меняется: подстраховку делает служба —
        /// держит p0 (`xray api bo`) и переходит на p1, только если p0 перестал отвечать (Supervisor.switchToAlive).
        /// Поле остаётся в формате обмена со службой: без него служба прежней версии не приняла бы описание подключения.
        public var failoverOnly: Bool
        public var clashSecret: String
        public var extraDirectProcesses: [String]
        /// DoH провайдера для адресов VPN-серверов (заголовок server-address-resolve-*), вместо «DNS напрямую».
        public var serverResolve: ServerResolve?
        public init(servers: [Server], settings: AppSettings, profile: RoutingProfile? = nil, chain: Server? = nil,
                    failoverOnly: Bool = false, clashSecret: String = "", extraDirectProcesses: [String] = [],
                    serverResolve: ServerResolve? = nil) {
            self.servers = servers; self.settings = settings; self.profile = profile; self.chain = chain
            self.failoverOnly = failoverOnly; self.clashSecret = clashSecret; self.extraDirectProcesses = extraDirectProcesses
            self.serverResolve = serverResolve
        }
    }

    public static func build(_ input: Input) -> BuiltConfig {
        let helper = helperConfig(servers: input.servers)
        let x = xray(input)
        let sb = input.settings.mode == .tun ? singBox(input) : nil
        return BuiltConfig(xray: x, singBox: sb, helper: helper, servers: input.servers)
    }

    // MARK: xray

    static let tcpTransports: Set<String> = ["tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade"]

    public static func xray(_ input: Input) -> String {
        let s = input.settings, servers = input.servers
        precondition(!servers.isEmpty)
        var outbounds: [[String: Any]] = []
        var helperIndex = 0
        let useChain = input.chain != nil && input.chain?.engine == .xray
        let useFrag = s.fragment || s.noises

        for (i, srv) in servers.enumerated() {
            var ob: [String: Any]
            if srv.engine == .singbox {
                ob = ["protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": Paths.helperBasePort + helperIndex]]]]
                helperIndex += 1
            } else {
                ob = srv.outbound
                let proto = ob["protocol"] as? String ?? ""
                var ss = ob["streamSettings"] as? [String: Any] ?? [:]
                let net = ss["network"] as? String ?? "tcp"
                let tcpBased = tcpTransports.contains(net) && ["vless", "vmess", "trojan", "shadowsocks", "socks"].contains(proto)
                if useChain || (useFrag && tcpBased) {
                    var so = ss["sockopt"] as? [String: Any] ?? [:]
                    so["dialerProxy"] = useChain ? "chain" : "fragment"
                    ss["sockopt"] = so
                    if ss["network"] == nil { ss["network"] = "tcp" }
                    ob["streamSettings"] = ss
                }
                if s.mux && tcpBased && net != "xhttp" && !hasFlow(ob) {
                    ob["mux"] = ["enabled": true, "concurrency": max(1, s.muxConcurrency), "xudpConcurrency": 16, "xudpProxyUDP443": "reject"]
                }
            }
            ob["tag"] = "p\(i)"
            outbounds.append(ob)
        }
        if useChain, var c = input.chain?.outbound {
            c["tag"] = "chain"
            if useFrag, var ss = c["streamSettings"] as? [String: Any], tcpTransports.contains(ss["network"] as? String ?? "tcp") {
                var so = ss["sockopt"] as? [String: Any] ?? [:]; so["dialerProxy"] = "fragment"; ss["sockopt"] = so; c["streamSettings"] = ss
            }
            outbounds.append(c)
        }
        if useFrag {
            var fs: [String: Any] = [:]
            if s.fragment {
                fs["fragment"] = ["packets": s.fragmentPackets, "length": s.fragmentLength, "interval": s.fragmentInterval]
            }
            if s.noises { fs["noises"] = [["type": s.noisesType, "packet": s.noisesPacket, "delay": s.noisesDelay]] }
            outbounds.append(["tag": "fragment", "protocol": "freedom", "settings": fs])
        }
        outbounds.append(["tag": "direct", "protocol": "freedom"])
        outbounds.append(["tag": "block", "protocol": "blackhole"])

        var config: [String: Any] = [:]
        let balanced = servers.count > 1
        let proxyTarget: [String: Any] = balanced ? ["balancerTag": "auto"] : ["outboundTag": "p0"]
        let p = input.profile
        var rules: [[String: Any]] = [["inboundTag": ["api"], "outboundTag": "api"]]
        // Проверка связи — всегда через сервер, до любых правил «напрямую» и «блокировать».
        rules.append(merge(["inboundTag": ["health"]], proxyTarget))
        // Пробные входы: через t{i} всегда идёт сервер p{i} — служба замеряет каждого кандидата отдельно.
        if balanced {
            for i in servers.indices { rules.append(["inboundTag": ["t\(i)"], "outboundTag": "p\(i)"]) }
        }
        if s.routingMode == .direct {
            rules.append(["network": "tcp,udp", "outboundTag": "direct"])
        } else {
            // Три группы правил; порядок — «блокировать → через VPN → напрямую», если профиль не задал свой (RouteOrder).
            var groups: [String: [[String: Any]]] = ["block": [], "proxy": [], "direct": []]
            var blockDomains = cleaned(s.blockDomains) + (p?.blockSites ?? [])
            if s.blockAds { blockDomains.append("geosite:category-ads-all") }
            let blockIPs = cleaned(s.blockIPs) + (p?.blockIPs ?? [])
            if !blockDomains.isEmpty { groups["block"]!.append(["domain": blockDomains.map(domainRule), "outboundTag": "block"]) }
            if !blockIPs.isEmpty { groups["block"]!.append(["ip": blockIPs.map(ipRule), "outboundTag": "block"]) }
            let proxyDomains = cleaned(s.proxyDomains) + (p?.proxySites ?? [])
            let proxyIPs = cleaned(s.proxyIPs) + (p?.proxyIPs ?? [])
            if !proxyDomains.isEmpty { groups["proxy"]!.append(merge(["domain": proxyDomains.map(domainRule)], proxyTarget)) }
            if !proxyIPs.isEmpty { groups["proxy"]!.append(merge(["ip": proxyIPs.map(ipRule)], proxyTarget)) }
            groups["direct"]!.append(["ip": ["geoip:private"], "outboundTag": "direct"])
            if s.routingMode == .rule {
                let directDomains = cleaned(s.directDomains) + (p?.directSites ?? [])
                let directIPs = cleaned(s.directIPs) + (p?.directIPs ?? [])
                if !directDomains.isEmpty { groups["direct"]!.append(["domain": directDomains.map(domainRule), "outboundTag": "direct"]) }
                if !directIPs.isEmpty { groups["direct"]!.append(["ip": directIPs.map(ipRule), "outboundTag": "direct"]) }
                if s.russiaDirect {
                    groups["direct"]!.append(["domain": DirectCountry.domains(s.directCountry), "outboundTag": "direct"])
                    let countryIPs = DirectCountry.ips(s.directCountry)
                    if !countryIPs.isEmpty { groups["direct"]!.append(["ip": countryIPs, "outboundTag": "direct"]) }
                }
            }
            for name in RoutingProfiles.routeGroups(p?.routeOrder) ?? ["block", "proxy", "direct"] { rules += groups[name] ?? [] }
            // 4. Остальное
            if s.routingMode == .rule, p?.globalProxy == false {
                rules.append(["network": "tcp,udp", "outboundTag": "direct"])
            } else {
                rules.append(merge(["network": "tcp,udp"], proxyTarget))
            }
        }

        var routing: [String: Any] = ["domainStrategy": p?.domainStrategy ?? s.domainStrategy, "rules": rules]
        if balanced {
            // Какой сервер из списка использовать, решает служба Tutun (замеры + порог переключения)
            // и задаёт ядру командой «api bo». До первой команды — p0 (самый быстрый по последней проверке).
            routing["balancers"] = [["tag": "auto", "selector": ["p"], "strategy": ["type": "random"]]]
        }

        let sniff: [String: Any] = ["enabled": s.sniffing, "destOverride": ["http", "tls", "quic"], "routeOnly": true]
        var inbounds: [[String: Any]] = [
            ["tag": "socks", "listen": "127.0.0.1", "port": Paths.socksPort, "protocol": "socks",
             "settings": ["udp": true], "sniffing": sniff],
            ["tag": "http", "listen": "127.0.0.1", "port": Paths.httpPort, "protocol": "http", "sniffing": sniff],
            ["tag": "api", "listen": "127.0.0.1", "port": Paths.apiPort, "protocol": "dokodemo-door",
             "settings": ["address": "127.0.0.1"]],
            ["tag": "health", "listen": "127.0.0.1", "port": Paths.healthPort, "protocol": "socks", "settings": ["udp": false]],
        ]
        if balanced {
            for i in servers.indices {
                inbounds.append(["tag": "t\(i)", "listen": "127.0.0.1", "port": Paths.probeBasePort + i, "protocol": "socks",
                                 "settings": ["udp": false]])
            }
        }
        if s.allowLAN {
            let auth = !s.lanUser.isEmpty && !s.lanPassword.isEmpty
            var socks: [String: Any] = ["udp": true]
            var http: [String: Any] = [:]
            if auth {
                socks["auth"] = "password"; socks["accounts"] = [["user": s.lanUser, "pass": s.lanPassword]]
                http["accounts"] = [["user": s.lanUser, "pass": s.lanPassword]]
            }
            inbounds.append(["tag": "lan-socks", "listen": "0.0.0.0", "port": s.lanSocksPort, "protocol": "socks", "settings": socks, "sniffing": sniff])
            inbounds.append(["tag": "lan-http", "listen": "0.0.0.0", "port": s.lanHttpPort, "protocol": "http", "settings": http, "sniffing": sniff])
        }

        var dnsServers: [Any] = [p?.remoteDNS ?? s.remoteDNS]
        if s.russiaDirect && s.routingMode == .rule {
            dnsServers.append(["address": DirectCountry.dnsAddress(s.directCountry, directDNS: p?.directDNS ?? s.directDNS),
                               "domains": DirectCountry.dnsDomains(s.directCountry)])
        }
        dnsServers.append("localhost")

        // Журнал соединений xray пишет каждый запрос (и опрос статистики раз в секунду) — включаем только в режиме «Отладка».
        config["log"] = ["loglevel": s.logLevel, "access": s.logLevel == "debug" ? "" : "none"]
        config["stats"] = [String: Any]()
        config["api"] = ["tag": "api", "services": ["StatsService", "RoutingService"]]
        config["policy"] = ["system": ["statsOutboundUplink": true, "statsOutboundDownlink": true]]
        var xrayDNS: [String: Any] = ["servers": dnsServers, "queryStrategy": s.ipv6 ? "UseIP" : "UseIPv4"]
        if let hosts = p?.dnsHosts, !hosts.isEmpty { xrayDNS["hosts"] = hosts }
        config["dns"] = xrayDNS
        config["inbounds"] = inbounds
        config["outbounds"] = outbounds
        config["routing"] = routing
        return LinkParser.toJSON(config)
    }

    static func hasFlow(_ ob: [String: Any]) -> Bool {
        let user = (((ob["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first?["users"] as? [[String: Any]])?.first
        return !((user?["flow"] as? String) ?? "").isEmpty
    }


    // MARK: вспомогательный sing-box

    /// Для серверов на sing-box: socks-вход 127.0.0.1:20000+k → этот сервер.
    public static func helperConfig(servers: [Server]) -> String? {
        let hs = servers.filter { $0.engine == .singbox }
        guard !hs.isEmpty else { return nil }
        var inbounds: [[String: Any]] = [], outbounds: [[String: Any]] = [], rules: [[String: Any]] = []
        for (k, s) in hs.enumerated() {
            inbounds.append(["type": "socks", "tag": "h\(k)", "listen": "127.0.0.1", "listen_port": Paths.helperBasePort + k])
            var ob = s.outbound; ob["tag"] = "o\(k)"
            outbounds.append(ob)
            rules.append(["inbound": ["h\(k)"], "outbound": "o\(k)"])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        let cfg: [String: Any] = ["log": ["level": "warn"], "inbounds": inbounds, "outbounds": outbounds,
                                  "route": ["rules": rules, "final": "direct", "auto_detect_interface": true]]
        return LinkParser.toJSON(cfg)
    }

    // MARK: sing-box TUN

    /// Ставит ли служба системный DNS мака в туннель (SystemDNSManager): только «весь трафик» и только когда
    /// остальное идёт через VPN. В режиме «всё напрямую» и «только выбранные приложения через VPN» DNS не трогаем.
    public static func capturesSystemDNS(_ s: AppSettings) -> Bool {
        s.mode == .tun && s.routingMode != .direct && !(s.appsMode == .include && !cleaned(s.includeApps).isEmpty)
    }

    /// DNS «напрямую» для туннеля: должен быть IP — его запрашивают в обход VPN.
    static func directDNSAddress(_ input: Input) -> String {
        let v = (input.profile?.directDNS ?? input.settings.directDNS).trimmingCharacters(in: .whitespaces)
        var a4 = in_addr()
        return inet_pton(AF_INET, v, &a4) == 1 ? v : "77.88.8.8"
    }

    /// Какие адреса служба ставит системным DNS, пока работает туннель: «DNS напрямую» и 1.1.1.1.
    /// Туннель перехватывает запросы к ним; настоящими серверами они становятся, только если настройка осталась после сбоя.
    public static func systemDNSPlaceholders(_ input: Input) -> [String] {
        let first = directDNSAddress(input)
        return first == "1.1.1.1" ? [first, "77.88.8.8"] : [first, "1.1.1.1"]
    }

    /// Имена VPN-серверов (не IP). Их адреса нельзя спрашивать через VPN: чтобы подключиться к серверу,
    /// нужно сначала знать его адрес — иначе замкнутый круг и зависшее подключение.
    static func serverHostnames(_ input: Input) -> [String] {
        let hosts = (input.servers + (input.chain.map { [$0] } ?? [])).map { $0.host.lowercased().trimmingCharacters(in: .whitespaces) }
        let names = hosts.filter { h in
            var a4 = in_addr(), a6 = in6_addr()
            return !h.isEmpty && inet_pton(AF_INET, h, &a4) != 1 && inet_pton(AF_INET6, h.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &a6) != 1
        }
        return Array(Set(names)).sorted()
    }

    public static func singBox(_ input: Input) -> String {
        let s = input.settings
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["process_path": [Paths.xray, Paths.singBox, Paths.bundledXray, Paths.bundledSingBox], "outbound": "direct"],
            ["ip_is_private": true, "outbound": "direct"],
        ]
        let ownProcesses = ["Tutun"] + input.extraDirectProcesses
        var final = "proxy"
        switch s.appsMode {
        case .exclude:
            rules.append(["process_name": ownProcesses + cleaned(s.directApps), "outbound": "direct"])
        case .include:
            rules.append(["process_name": ownProcesses, "outbound": "direct"])
            let inc = cleaned(s.includeApps)
            if !inc.isEmpty { rules.append(["process_name": inc, "outbound": "proxy"]); final = "direct" }
        }
        if s.routingMode == .direct { final = "direct" }

        var tun: [String: Any] = [
            "type": "tun", "tag": "tun", "interface_name": "utun233",
            // IPv6 в туннеле — только при включённой настройке. Служба 2.7–2.9 всегда давала туннелю IPv6 и отклоняла его
            // правилом: macOS и Chromium видели IPv6-маршрут, шли на AAAA-адрес (claude.ai — 2607:6bc0::10), sing-box
            // принимал соединение и рвал его после разбора TLS — ERR_CONNECTION_RESET без перехода на IPv4 (11.11.2026).
            "address": s.ipv6 ? ["172.19.0.1/30", "fdfe:dcba:9876::1/126"] : ["172.19.0.1/30"],
            "mtu": 9000, "auto_route": true, "strict_route": true, "stack": "mixed",
        ]
        let excluded = cleaned(s.excludedRoutes).compactMap(cidr)
        if !excluded.isEmpty { tun["route_exclude_address"] = excluded }

        let remote = input.profile?.remoteDNS ?? s.remoteDNS
        var remoteServer = dnsServer(remote, tag: "remote")
        remoteServer["detour"] = "proxy"
        // «direct-dns» — обычный DNS в обход VPN (sing-box ходит к нему через физический интерфейс).
        // Через него: адреса самих VPN-серверов (иначе замкнутый круг, когда системный DNS мака смотрит в туннель),
        // доменные зоны страны при «Сайты страны — напрямую», и собственные имена исходящих соединений sing-box.
        // «local» (системный резолвер) — только для режима «всё напрямую», когда системный DNS не подменяется.
        var dnsRules: [[String: Any]] = []
        var extraServers: [[String: Any]] = []
        // Закреплённые адреса из профиля (Happ DnsHosts): системный DNS мака идёт через туннель, поэтому отвечать должен и он.
        if let pinned = input.profile?.dnsHosts, !pinned.isEmpty {
            extraServers.append(["type": "hosts", "tag": "pinned", "predefined": pinned.mapValues { [$0] }])
            dnsRules.append(["domain": pinned.keys.sorted(), "action": "route", "server": "pinned"])
        }
        let hosts = serverHostnames(input)
        var serverDNS = "direct-dns"
        if let r = input.serverResolve, let u = URL(string: r.dohURL), let host = u.host {
            // DoH провайдера по IP (имя DoH-сервера тоже пришлось бы где-то спрашивать), в обход VPN.
            var doh: [String: Any] = ["type": "https", "tag": "server-resolve", "server": r.bootstrapIP, "tls": ["server_name": host]]
            if let port = u.port { doh["server_port"] = port }
            if !u.path.isEmpty { doh["path"] = u.path }
            extraServers.append(doh)
            serverDNS = "server-resolve"
        }
        if !hosts.isEmpty { dnsRules.append(["domain": hosts, "action": "route", "server": serverDNS]) }
        if s.routingMode == .rule && s.russiaDirect {
            dnsRules.append(["domain_suffix": DirectCountry.zones(s.directCountry), "action": "route", "server": "direct-dns"])
        }
        var dns: [String: Any] = [
            "servers": [remoteServer, ["type": "local", "tag": "local"],
                        ["type": "udp", "tag": "direct-dns", "server": directDNSAddress(input)]] + extraServers,
            "final": s.routingMode == .direct ? "local" : "remote",
            "strategy": s.ipv6 ? "prefer_ipv4" : "ipv4_only",
        ]
        if !dnsRules.isEmpty { dns["rules"] = dnsRules }
        let config: [String: Any] = [
            // Время пишет журнал службы; своя метка sing-box только удлиняла строки.
            "log": ["level": "warn", "timestamp": false],
            "dns": dns,
            "inbounds": [tun],
            "outbounds": [
                ["type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": Paths.socksPort, "version": "5"],
                ["type": "direct", "tag": "direct"],
            ],
            "route": [
                "auto_detect_interface": true,
                "default_domain_resolver": "direct-dns",
                "final": final,
                "rules": rules,
            ],
            "experimental": ["clash_api": ["external_controller": "127.0.0.1:\(Paths.clashPort)", "secret": input.clashSecret]],
        ]
        return LinkParser.toJSON(config)
    }

    /// «1.1.1.1» → DoH по IP (у Cloudflare/Google/Quad9), «https://…» → DoH, «tls://…» → DoT, иначе TCP.
    static func dnsServer(_ raw: String, tag: String) -> [String: Any] {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: v), let scheme = u.scheme, let host = u.host {
            switch scheme {
            case "https": var d: [String: Any] = ["type": "https", "tag": tag, "server": host]; if !u.path.isEmpty { d["path"] = u.path }; return d
            case "tls": return ["type": "tls", "tag": tag, "server": host]
            case "quic": return ["type": "quic", "tag": tag, "server": host]
            default: break
            }
        }
        let dohIPs: Set<String> = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "94.140.14.14"]
        if dohIPs.contains(v) { return ["type": "https", "tag": tag, "server": v] }
        return ["type": "tcp", "tag": tag, "server": v.isEmpty ? "1.1.1.1" : v]
    }

    // MARK: helpers

    static func cleaned(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// «example.com» → домен и все поддомены; «geosite:», «regexp:», «full:», «keyword:» — как есть.
    static func domainRule(_ s: String) -> String {
        if s.contains(":") { return s }
        return "domain:" + s.lowercased()
    }

    static func ipRule(_ s: String) -> String { s }

    /// Проверка и нормализация CIDR: «1.2.3.4» → «1.2.3.4/32».
    static func cidr(_ s: String) -> String? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, !s.hasPrefix("/"), !s.hasSuffix("/"), parts.count <= 2 else { return nil }
        let ip = String(first)
        var a4 = in_addr(), a6 = in6_addr()
        let isV4 = inet_pton(AF_INET, ip, &a4) == 1, isV6 = inet_pton(AF_INET6, ip, &a6) == 1
        guard isV4 || isV6 else { return nil }
        if parts.count == 2, let n = Int(parts[1]), n >= 0, n <= (isV4 ? 32 : 128) { return s }
        return parts.count == 1 ? ip + (isV4 ? "/32" : "/128") : nil
    }

    static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        a.merging(b) { _, new in new }
    }
}
