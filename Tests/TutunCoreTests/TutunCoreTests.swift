import XCTest
import TutunShared
@testable import TutunCore

final class TutunCoreTests: XCTestCase {
    func testPortableImportPreservesDeviceSettings() throws {
        var local = AppSettings()
        local.hwid = "local-device-only"
        local.launchAtLogin = true
        local.showInDock = false
        local.directApps = ["Mac-only-app"]
        local.onDemand = true
        local.trustedSSIDs = ["Local WiFi"]
        local.chainServerID = "old-chain"
        var common = TutunShared.ConnectionPreferences()
        common.remoteDNS = "9.9.9.9"
        common.blockAds = true
        let result = try PortableProfileAdapter.applying(common, to: local)
        XCTAssertEqual(result.hwid, local.hwid)
        XCTAssertEqual(result.launchAtLogin, local.launchAtLogin)
        XCTAssertEqual(result.showInDock, local.showInDock)
        XCTAssertEqual(result.directApps, local.directApps)
        XCTAssertEqual(result.onDemand, local.onDemand)
        XCTAssertEqual(result.trustedSSIDs, local.trustedSSIDs)
        XCTAssertEqual(result.remoteDNS, "9.9.9.9")
        XCTAssertTrue(result.blockAds)
        XCTAssertNil(result.chainServerID)
    }

    func testPortableExportUsesExplicitAcceptedSnapshot() throws {
        var accepted = AppSettings()
        accepted.remoteDNS = "9.9.9.9"
        let profile = try PortableProfileAdapter.makeProfile(servers: [], subscriptions: [], routingProfiles: [], acceptedSettings: accepted)
        XCTAssertEqual(profile.preferences.remoteDNS, accepted.remoteDNS)
        XCTAssertEqual(try TutunShared.ConfigurationProfile.decode(profile.encode()), profile)
    }

    func testPortableUnknownFieldsCannotOverwriteDeviceIdentity() throws {
        let data = try TutunShared.ConfigurationProfile().encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var prefs = try XCTUnwrap(object["preferences"] as? [String: Any])
        prefs["hwid"] = "foreign-device"
        prefs["launchAtLogin"] = true
        object["preferences"] = prefs
        let profile = try TutunShared.ConfigurationProfile.decode(JSONSerialization.data(withJSONObject: object))
        var local = AppSettings()
        local.hwid = "original-device"
        let imported = try PortableProfileAdapter.applying(profile.preferences, to: local)
        XCTAssertEqual(imported.hwid, "original-device")
        XCTAssertFalse(imported.launchAtLogin)
    }
    func testMalformedCIDRDoesNotCrash() {
        for invalid in ["", "/", "//", "/32", "1.2.3.4/", "1.2.3.4//32", "1.2.3.4/33", "::1/129", "no-ip"] {
            XCTAssertNil(ConfigBuilder.cidr(invalid), invalid)
        }
        XCTAssertEqual(ConfigBuilder.cidr("1.2.3.4"), "1.2.3.4/32")
        XCTAssertEqual(ConfigBuilder.cidr("::1"), "::1/128")
        XCTAssertEqual(ConfigBuilder.cidr("10.0.0.0/8"), "10.0.0.0/8")
    }

    func testSelectingServerDoesNotAcceptDraftSettings() {
        let accepted = AppSettings()
        var oldDraft = accepted
        oldDraft.onDemand = true
        oldDraft.trustedSSIDs = ["Unaccepted WiFi"]
        oldDraft.mode = .proxy
        oldDraft.geoAutoUpdate = true
        oldDraft.showInDock = false
        var newDraft = oldDraft
        newDraft.selectedServerID = "new-server"
        newDraft.autoSelect = false
        let runtime = SettingsPolicy.mergingRuntimeChanges(from: oldDraft, to: newDraft, accepted: accepted)
        XCTAssertEqual(runtime.selectedServerID, "new-server")
        XCTAssertFalse(runtime.autoSelect)
        XCTAssertEqual(runtime.onDemand, accepted.onDemand)
        XCTAssertEqual(runtime.trustedSSIDs, accepted.trustedSSIDs)
        XCTAssertEqual(runtime.mode, accepted.mode)
        XCTAssertEqual(runtime.geoAutoUpdate, accepted.geoAutoUpdate)
        XCTAssertEqual(runtime.showInDock, accepted.showInDock)
        XCTAssertNotEqual(newDraft, runtime)
    }

    func testDaemonRejectsUnsafeConnectionPlans() throws {
        let servers = try samples.map { try LinkParser.parse($0) }
        let valid = ConfigBuilder.Input(servers: servers, settings: AppSettings())
        XCTAssertNoThrow(try ConnectionValidation.validate(valid))
        XCTAssertThrowsError(try ConnectionValidation.validate(.init(servers: [], settings: AppSettings())))
        var invalid = valid
        invalid.settings.testURL = "file:///etc/passwd"
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid = valid
        invalid.settings.allowLAN = true
        invalid.settings.lanUser = "phone"; invalid.settings.lanPassword = "secret"
        XCTAssertNoThrow(try ConnectionValidation.validate(invalid))
        invalid.settings.lanSocksPort = Paths.apiPort
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        // Раздача в сеть без логина или пароля открыла бы VPN всем соседям по Wi-Fi.
        invalid = valid
        invalid.settings.allowLAN = true
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid.settings.lanUser = "phone"
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid.settings.lanUser = " "; invalid.settings.lanPassword = "secret"
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid = valid
        invalid.servers[0].outboundJSON = #"{"protocol":"vless","streamSettings":{"tlsSettings":{"certificates":[{"keyFile":"/root/private"}]}}}"#
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid = valid
        invalid.servers[0].outboundJSON = #"{"protocol":"freedom"}"#
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid = valid
        invalid.servers[0].outboundJSON = #"{"protocol":"vless","streamSettings":{"tlsSettings":{"masterKeyLog":"/root/private"}}}"#
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
        invalid = valid
        invalid.settings.directDomains = ["ext:../../private:example"]
        XCTAssertThrowsError(try ConnectionValidation.validate(invalid))
    }

    func testConnectionPlanSurvivesIPCEncoding() throws {
        let servers = try samples.map { try LinkParser.parse($0) }
        var request = DaemonRequest(cmd: .start)
        request.connection = .init(servers: servers, settings: AppSettings())
        let decoded = try JSONDecoder.tunnel.decode(DaemonRequest.self, from: JSONEncoder.tunnel.encode(request))
        let plan = try XCTUnwrap(decoded.connection)
        XCTAssertEqual(plan.servers.count, servers.count)
        XCTAssertEqual(plan.settings, AppSettings())
        XCTAssertNoThrow(try ConnectionValidation.validate(plan))
        XCTAssertNil(decoded.xrayConfig)
    }
    let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    let wgKey = "cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ="

    var samples: [String] {
        let vmessJSON = #"{"v":"2","ps":"VM WS","add":"vm.example.com","port":"443","id":"\#(uuid)","aid":"0","net":"ws","type":"none","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"cdn.example.com"}"#
        return [
            "vless://\(uuid)@1.2.3.4:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBLjF4hs&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F",
            "vless://\(uuid)@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fxh&mode=auto&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#XHTTP",
            "vless://\(uuid)@g.example.com:443?type=grpc&serviceName=svc&security=tls&sni=g.example.com#gRPC",
            "trojan://pass%40word@t.example.com:443?sni=t.example.com&type=ws&path=%2Ftr#Trojan",
            "vmess://" + Data(vmessJSON.utf8).base64EncodedString(),
            "ss://" + Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString() + "@5.6.7.8:8388#SS",
            "ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2BOTw%3D%3D@9.9.9.9:443#SS2022",
            "hysteria2://authpw@h.example.com:8443?sni=h.example.com#HY2",
            "hysteria2://authpw@o.example.com:443?sni=o.example.com&obfs=salamander&obfs-password=secret#HY2-obfs",
            "tuic://\(uuid):pw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com#TUIC",
            "wireguard://\(wgKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)@wg.example.com:51820?publickey=\(wgKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&address=10.7.0.2/32&reserved=1,2,3#WG",
            "socks://" + Data("user:pass".utf8).base64EncodedString() + "@s.example.com:1080#SOCKS",
        ]
    }

    func testParseAll() throws {
        let servers = try samples.map { try LinkParser.parse($0) }
        XCTAssertEqual(servers.map(\.proto), ["vless", "vless", "vless", "trojan", "vmess", "shadowsocks", "shadowsocks",
                                              "hysteria2", "hysteria2", "tuic", "wireguard", "socks"])
        XCTAssertEqual(servers[0].name, "Германия")
        XCTAssertEqual(servers[7].engine, .xray)
        XCTAssertEqual(servers[8].engine, .singbox)
        XCTAssertEqual(servers[9].engine, .singbox)
        XCTAssertNotNil(servers[0].rawLink)
        let trojanPw = ((servers[3].outbound["settings"] as? [String: Any])?["servers"] as? [[String: Any]])?.first?["password"] as? String
        XCTAssertEqual(trojanPw, "pass@word")
        XCTAssertEqual(Set(servers.map(\.id)).count, servers.count)
    }

    func testBatchWithProfiles() {
        let profileJSON = #"{"Name":"RU","DirectSites":["geosite:category-ru"],"ProxySites":["youtube.com"],"BlockSites":["geosite:category-ads-all"],"DomainStrategy":"IPIfNonMatch","GlobalProxy":"true"}"#
        let lines = samples + ["happ://routing/add/" + Data(profileJSON.utf8).base64EncodedString(), "happ://crypt4/abcdef", "awg://x@y:1"]
        let b = LinkParser.parseBatch(Data(lines.joined(separator: "\n").utf8).base64EncodedData(), subscriptionID: nil)
        XCTAssertEqual(b.servers.count, samples.count)
        XCTAssertEqual(b.profiles.count, 1)
        XCTAssertEqual(b.profiles.first?.proxySites, ["youtube.com"])
        XCTAssertEqual(b.errors.count, 2, "\(b.errors)")
        let back = RoutingProfiles.parseLink(RoutingProfiles.link(for: b.profiles[0]))
        XCTAssertEqual(back?.blockSites, ["geosite:category-ads-all"])
    }

    func testWireGuardConf() throws {
        let conf = "[Interface]\nPrivateKey = \(wgKey)\nAddress = 10.8.0.2/32\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = \(wgKey)\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n"
        let b = LinkParser.parseBatch(Data(conf.utf8), subscriptionID: nil)
        XCTAssertEqual(b.servers.first?.proto, "wireguard")
        let awg = conf.replacingOccurrences(of: "DNS", with: "Jc = 4\nDNS")
        XCTAssertTrue(LinkParser.parseBatch(Data(awg.utf8), subscriptionID: nil).servers.isEmpty)
    }

    func testSubscriptionBodyJSON() {
        let cfg = #"[{"remarks":"JSON сервер","outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"j.example.com","port":443,"users":[{"id":"\#(uuid)","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","sockopt":{"dialerProxy":"frag"}}},{"tag":"direct","protocol":"freedom"}]}]"#
        let r = LinkParser.parseBatch(Data(cfg.utf8), subscriptionID: nil)
        XCTAssertEqual(r.servers.count, 1)
        XCTAssertEqual(r.servers[0].name, "JSON сервер")
        XCTAssertFalse(r.servers[0].outboundJSON.contains("dialerProxy"))
    }

    func testPlainVlessRejected() throws {
        let plain = try LinkParser.parse("vless://\(uuid)@de.example.com:80?type=ws&security=none&path=%2F#Plain")
        XCTAssertNotNil(LinkParser.rejectReason(plain))
        let lan = try LinkParser.parse("vless://\(uuid)@192.168.1.5:80?type=tcp&security=none#LAN")
        XCTAssertNil(LinkParser.rejectReason(lan))
    }

    // MARK: настоящие ядра

    var bin: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("vendor/bin")
    }

    func checkWithCores(_ built: BuiltConfig, file: StaticString = #filePath, line: UInt = #line) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-test-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let x = tmp.appendingPathComponent("x.json")
        try built.xray.write(to: x, atomically: true, encoding: .utf8)
        let (c1, o1) = run(bin.appendingPathComponent("xray").path, ["run", "-test", "-c", x.path], env: ["XRAY_LOCATION_ASSET": bin.path])
        XCTAssertEqual(c1, 0, errorsOnly(o1), file: file, line: line)
        for (name, cfg) in [("s", built.singBox), ("h", built.helper)] {
            guard let cfg else { continue }
            let p = tmp.appendingPathComponent("\(name).json")
            try cfg.write(to: p, atomically: true, encoding: .utf8)
            let (c, o) = run(bin.appendingPathComponent("sing-box").path, ["check", "-c", p.path], env: [:])
            XCTAssertEqual(c, 0, "\(name): \(o)", file: file, line: line)
        }
    }

    func testDirectCountryRulesAcceptedByXray() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("xray").path), "нет vendor/bin")
        let servers = [try LinkParser.parse(samples[0])]
        for code in DirectCountry.codes {
            var s = AppSettings(); s.directCountry = code
            try ConnectionValidation.validate(.init(servers: servers, settings: s))
            let built = try ConfigBuilder.build(.init(servers: servers, settings: s))
            XCTAssertEqual(built.xray.contains("geoip:\(code)"), DirectCountry.withIPs.contains(code), code)
            let dns = code == "ru" ? "77.88.8.8" : "localhost"
            XCTAssertTrue(built.xray.contains(dns), code)
            try checkWithCores(built)
        }
        var bad = AppSettings(); bad.directCountry = "xx"
        XCTAssertThrowsError(try ConnectionValidation.validate(.init(servers: servers, settings: bad)))
        // Старые настройки без поля — Россия; «Нет» = russiaDirect выключен.
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).directCountry, "ru")
        var off = AppSettings(); off.russiaDirect = false; off.directCountry = "cn"
        XCTAssertFalse(try ConfigBuilder.build(.init(servers: servers, settings: off)).xray.contains("geoip:cn"))
        // Переносимый профиль: старый без поля читается, страна переносится.
        var cn = AppSettings(); cn.directCountry = "cn"
        let prof = try PortableProfileAdapter.makeProfile(servers: [], subscriptions: [], routingProfiles: [], acceptedSettings: cn)
        XCTAssertEqual(try PortableProfileAdapter.applying(prof.preferences, to: AppSettings()).directCountry, "cn")
    }

    func testConfigsAcceptedByCores() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("xray").path), "нет vendor/bin")
        let servers = try samples.map { try LinkParser.parse($0) }
        var s = AppSettings()
        s.directDomains = ["example.org", "geosite:apple"]; s.proxyDomains = ["youtube.com"]; s.blockDomains = ["ads.example.com"]
        s.directIPs = ["8.8.8.8/32"]; s.blockIPs = ["1.2.3.0/24"]; s.excludedRoutes = ["192.0.2.10", "198.51.100.0/24", "мусор"]
        s.directApps = ["Telegram"]; s.blockAds = true; s.fragment = true; s.noises = true; s.mux = true
        s.allowLAN = true; s.lanUser = "u"; s.lanPassword = "p"; s.ipv6 = true; s.remoteDNS = "https://dns.google/dns-query"
        let profile = RoutingProfiles.parseJSON(Data(#"{"Name":"P","DirectSites":["geosite:category-gov-ru"],"ProxyIp":["91.108.4.0/22"],"GlobalProxy":"true"}"#.utf8))

        // Автовыбор по всем серверам
        try checkWithCores(ConfigBuilder.build(.init(servers: servers, settings: s, profile: profile, clashSecret: "x")))
        // Один сервер, цепочка через другой, режим прокси
        var s2 = s; s2.mode = .proxy; s2.fragment = false; s2.noises = false
        try checkWithCores(ConfigBuilder.build(.init(servers: [servers[1]], settings: s2, chain: servers[0])))
        // Ручной выбор с подстраховкой, только выбранные приложения, всё напрямую
        var s3 = s; s3.appsMode = .include; s3.includeApps = ["Safari"]; s3.routingMode = .direct
        try checkWithCores(ConfigBuilder.build(.init(servers: [servers[0], servers[2]], settings: s3, failoverOnly: true)))
        // Глобальный режим
        var s4 = AppSettings(); s4.routingMode = .global
        try checkWithCores(ConfigBuilder.build(.init(servers: [servers[8], servers[9]], settings: s4)))
    }

    func testHealthCheckBypassesRoutingAndTunnelHasNoIPv6WhenOff() throws {
        let servers = try samples.prefix(3).map { try LinkParser.parse($0) }
        var s = AppSettings(); s.directDomains = ["gstatic.com"]; s.blockDomains = ["www.gstatic.com"]
        let profile = RoutingProfiles.parseJSON(Data(#"{"Name":"P","DirectSites":["example.org"],"GlobalProxy":"false"}"#.utf8))
        for list in [[servers[0]], servers] {
            let x = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(.init(servers: list, settings: s, profile: profile)).xray.utf8)) as! [String: Any]
            let rules = (x["routing"] as! [String: Any])["rules"] as! [[String: Any]]
            // Правило проверки — сразу после api, раньше блокировки и «напрямую», и ведёт на сервер.
            XCTAssertEqual(rules[1]["inboundTag"] as? [String], ["health"])
            if list.count > 1 { XCTAssertEqual(rules[1]["balancerTag"] as? String, "auto") }
            else { XCTAssertEqual(rules[1]["outboundTag"] as? String, "p0") }
            let inbounds = x["inbounds"] as! [[String: Any]]
            XCTAssertTrue(inbounds.contains { $0["tag"] as? String == "health" && $0["port"] as? Int == Paths.healthPort && $0["listen"] as? String == "127.0.0.1" })
        }
        func tun(_ ipv6: Bool) throws -> (addresses: [String], rejectsV6: Bool) {
            var t = s; t.ipv6 = ipv6
            let sb = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(.init(servers: [servers[0]], settings: t)).singBox!.utf8)) as! [String: Any]
            let tunIn = (sb["inbounds"] as! [[String: Any]])[0]
            let rules = (sb["route"] as! [String: Any])["rules"] as! [[String: Any]]
            let rejects = rules.contains { $0["action"] as? String == "reject" }
            return (tunIn["address"] as! [String], rejects)
        }
        // Без настройки у туннеля нет IPv6 и нет правил отказа: иначе программы шли на IPv6-адрес (claude.ai),
        // а туннель рвал уже принятое соединение — ERR_CONNECTION_RESET без перехода на IPv4 (11.11.2026).
        XCTAssertFalse(try tun(false).addresses.contains { $0.contains(":") })
        XCTAssertFalse(try tun(false).rejectsV6)
        XCTAssertTrue(try tun(true).addresses.contains { $0.contains(":") })
        XCTAssertFalse(try tun(true).rejectsV6)
        // Порт проверки нельзя занять раздачей в сеть.
        var lan = AppSettings(); lan.allowLAN = true; lan.lanUser = "u"; lan.lanPassword = "p"; lan.lanSocksPort = Paths.healthPort
        XCTAssertThrowsError(try ConnectionValidation.validate(.init(servers: [servers[0]], settings: lan)))
    }

    /// DNS мака в туннеле: адреса VPN-серверов и зоны страны — в обход VPN (иначе замкнутый круг), остальное — через VPN.
    func testTunnelDNSResolvesServersDirectlyAndRestThroughVPN() throws {
        var named = try LinkParser.parse(samples[0]); named.host = "Vpn.Example.NET"
        var byIP = try LinkParser.parse(samples[1]); byIP.host = "203.0.113.7"
        var s = AppSettings(); s.directCountry = "ru"; s.directDNS = "77.88.8.8"
        func dns(_ settings: AppSettings, _ servers: [Server], profile: RoutingProfile? = nil) throws -> [String: Any] {
            let sb = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(.init(servers: servers, settings: settings, profile: profile)).singBox!.utf8)) as! [String: Any]
            XCTAssertEqual((sb["route"] as! [String: Any])["default_domain_resolver"] as? String, "direct-dns")
            return sb["dns"] as! [String: Any]
        }
        let d = try dns(s, [named, byIP])
        let rules = d["rules"] as! [[String: Any]]
        XCTAssertEqual(rules[0]["domain"] as? [String], ["vpn.example.net"])   // IP-сервер в правило не попадает
        XCTAssertEqual(rules[0]["server"] as? String, "direct-dns")
        XCTAssertEqual(rules[1]["domain_suffix"] as? [String], ["ru", "su", "xn--p1ai"])
        XCTAssertEqual(d["final"] as? String, "remote")
        let direct = (d["servers"] as! [[String: Any]]).first { $0["tag"] as? String == "direct-dns" }
        XCTAssertEqual(direct?["server"] as? String, "77.88.8.8")
        // «DNS напрямую» не IP — запасной IP, а не имя, которое пришлось бы где-то спрашивать.
        var odd = s; odd.directDNS = "localhost"; odd.russiaDirect = false
        let d2 = try dns(odd, [byIP])
        XCTAssertNil(d2["rules"])
        XCTAssertEqual((d2["servers"] as! [[String: Any]]).first { $0["tag"] as? String == "direct-dns" }?["server"] as? String, "77.88.8.8")
        // Когда служба подменяет DNS мака.
        XCTAssertTrue(ConfigBuilder.capturesSystemDNS(AppSettings()))
        var proxy = AppSettings(); proxy.mode = .proxy
        var allDirect = AppSettings(); allDirect.routingMode = .direct
        var onlyApps = AppSettings(); onlyApps.appsMode = .include; onlyApps.includeApps = ["Safari"]
        var emptyInclude = AppSettings(); emptyInclude.appsMode = .include
        XCTAssertFalse(ConfigBuilder.capturesSystemDNS(proxy))
        XCTAssertFalse(ConfigBuilder.capturesSystemDNS(allDirect))
        XCTAssertFalse(ConfigBuilder.capturesSystemDNS(onlyApps))
        XCTAssertTrue(ConfigBuilder.capturesSystemDNS(emptyInclude))
    }

    /// Профили в формате Happ (генератор Happ, roscomvpn): ключи DNS в их регистре, DoH, закреплённые адреса, порядок групп.
    func testHappProfileKeysDnsHostsAndRouteOrder() throws {
        let json = #"{"Name":"RoscomVPN","GlobalProxy":"true","RemoteDns":"8.8.8.8","DomesticDns":"77.88.8.8","RemoteDNSType":"DoH","RemoteDNSDomain":"https://8.8.8.8/dns-query","RemoteDNSIP":"8.8.4.4","DomesticDNSType":"DoH","DomesticDNSDomain":"https://77.88.8.8/dns-query","DomesticDNSIP":"77.88.8.1","DnsHosts":{"lkfl2.nalog.ru":"213.24.64.175","bad host":"1.2.3.4","x.example":"not-an-ip"},"RouteOrder":"proxy-direct-block","DirectSites":["geosite:category-ru"],"ProxySites":["geosite:youtube"],"BlockSites":["geosite:category-ads-all"]}"#
        let p = try XCTUnwrap(RoutingProfiles.parseJSON(Data(json.utf8)))
        XCTAssertEqual(p.remoteDNS, "https://8.8.8.8/dns-query")
        XCTAssertEqual(p.directDNS, "77.88.8.1")
        XCTAssertEqual(p.dnsHosts, ["lkfl2.nalog.ru": "213.24.64.175"])
        XCTAssertEqual(p.routeOrder, "proxy-direct-block")
        // Без типа DoH — IP в регистре Happ; мусорный порядок не принимается.
        let plain = try XCTUnwrap(RoutingProfiles.parseJSON(Data(#"{"Name":"P","RemoteDNSIP":"9.9.9.9","RouteOrder":"proxy-proxy-block","DirectSites":["a.example"]}"#.utf8)))
        XCTAssertEqual(plain.remoteDNS, "9.9.9.9"); XCTAssertNil(plain.routeOrder)
        // Ссылка туда-обратно сохраняет новые поля.
        let again = try XCTUnwrap(RoutingProfiles.parseLink(RoutingProfiles.link(for: p)))
        XCTAssertEqual(again.dnsHosts, p.dnsHosts); XCTAssertEqual(again.routeOrder, p.routeOrder)

        let servers = [try LinkParser.parse(samples[0])]
        func order(_ profile: RoutingProfile) throws -> [String] {
            let x = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(.init(servers: servers, settings: AppSettings(), profile: profile)).xray.utf8)) as! [String: Any]
            let rules = (x["routing"] as! [String: Any])["rules"] as! [[String: Any]]
            return rules.compactMap { r in (r["domain"] as? [String]).flatMap { d in d.contains("geosite:youtube") ? "proxy" : d.contains("geosite:category-ads-all") ? "block" : d.contains("geosite:category-ru") && d.count == 1 ? "direct" : nil } }
        }
        XCTAssertEqual(try order(p), ["proxy", "direct", "block"])
        var standard = p; standard.routeOrder = nil
        XCTAssertEqual(try order(standard), ["block", "proxy", "direct"])
        let built = ConfigBuilder.build(.init(servers: servers, settings: AppSettings(), profile: p))
        let x = try JSONSerialization.jsonObject(with: Data(built.xray.utf8)) as! [String: Any]
        XCTAssertEqual(((x["dns"] as! [String: Any])["hosts"] as? [String: String])?["lkfl2.nalog.ru"], "213.24.64.175")
        let sb = try JSONSerialization.jsonObject(with: Data(built.singBox!.utf8)) as! [String: Any]
        let dnsRules = (sb["dns"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(dnsRules[0]["server"] as? String, "pinned")
        XCTAssertEqual(dnsRules[0]["domain"] as? [String], ["lkfl2.nalog.ru"])
        if FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("xray").path) { try checkWithCores(built) }
    }

    /// Подстраховка (сервер + запасной): служба начинает с p0 и может проверить и выбрать p1 —
    /// для этого в конфиге нужны балансировщик и отдельные пробные входы на каждый сервер.
    func testFailoverPairGivesServiceWhatItNeedsToSwitch() throws {
        let servers = try samples.prefix(2).map { try LinkParser.parse($0) }
        let x = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(.init(servers: servers, settings: AppSettings(), failoverOnly: true)).xray.utf8)) as! [String: Any]
        let routing = x["routing"] as! [String: Any]
        let balancers = routing["balancers"] as! [[String: Any]]
        XCTAssertEqual(balancers.first?["tag"] as? String, "auto")
        let rules = routing["rules"] as! [[String: Any]]
        for i in 0..<2 {
            XCTAssertTrue(rules.contains { ($0["inboundTag"] as? [String]) == ["t\(i)"] && $0["outboundTag"] as? String == "p\(i)" })
            XCTAssertTrue((x["inbounds"] as! [[String: Any]]).contains { $0["tag"] as? String == "t\(i)" && $0["port"] as? Int == Paths.probeBasePort + i })
        }
    }

    /// Служба отдаёт конфиги xray и вспомогательного sing-box через стандартный ввод (ядра без прав, см. tutun-drop).
    func testCoresAcceptConfigsOnStdin() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("xray").path), "нет vendor/bin")
        func stdinRun(_ exe: String, _ args: [String], _ input: String, env: [String: String] = [:]) throws -> (Int32, String) {
            let p = Process(); p.executableURL = bin.appendingPathComponent(exe); p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let inPipe = Pipe(), out = Pipe(); p.standardInput = inPipe; p.standardOutput = out; p.standardError = out
            try p.run()
            DispatchQueue.global().async { try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, text)
        }
        let servers = try samples.map { try LinkParser.parse($0) }
        XCTAssertTrue(servers.contains { $0.engine == .singbox }, "нужен сервер для вспомогательного sing-box")
        var s = AppSettings(); s.blockAds = true; s.fragment = true
        s.directDomains = (0..<3000).map { "site\($0).example" }   // больше буфера канала (64 КБ)
        let built = ConfigBuilder.build(.init(servers: Array(servers.prefix(25)), settings: s))
        let asset = ["XRAY_LOCATION_ASSET": bin.path]
        // Большой конфиг (все образцы) не помещается в буфер канала целиком — пишется в фоне.
        XCTAssertGreaterThan(built.xray.utf8.count, 64 * 1024)
        let (cx, ox) = try stdinRun("xray", ["run", "-test", "-c", "stdin:"], built.xray, env: asset)
        XCTAssertEqual(cx, 0, ox)
        let (ch, oh) = try stdinRun("sing-box", ["check", "-c", "stdin"], try XCTUnwrap(built.helper))
        XCTAssertEqual(ch, 0, oh)
        // Ошибка в конфиге через stdin по-прежнему видна службе (код и текст для «tag pN»).
        let broken = built.xray.replacingOccurrences(of: #""protocol":"vless""#, with: #""protocol":"nope""#)
        XCTAssertNotEqual(try stdinRun("xray", ["run", "-test", "-c", "stdin:"], broken, env: asset).0, 0)
    }

    /// Офлайн-проверка настоящей подписки: TUTUN_REAL_STORE=~/Library/Application Support/Tutun/app.json swift test
    func testRealStoreAcceptedByXray() throws {
        guard let path = ProcessInfo.processInfo.environment["TUTUN_REAL_STORE"] else { throw XCTSkip("нет TUTUN_REAL_STORE") }
        struct Store: Decodable { var servers: [Server] }
        let store = try JSONDecoder.tunnel.decode(Store.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let usable = store.servers.filter { LinkParser.rejectReason($0) == nil }
        print("всего \(store.servers.count), годных \(usable.count)")
        var s = AppSettings(); s.fragment = true; s.blockAds = true
        try checkWithCores(ConfigBuilder.build(.init(servers: usable, settings: s, clashSecret: "x")))
    }

    func errorsOnly(_ s: String) -> String { s.components(separatedBy: "\n").filter { !$0.contains("[Warning]") }.joined(separator: "\n") }

    func run(_ exe: String, _ args: [String], env: [String: String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testAppVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("v2.10.0", than: "2.9"))
        XCTAssertTrue(AppVersion.isNewer("2.1", than: "2.0.9"))
        XCTAssertFalse(AppVersion.isNewer("2.1.0", than: "2.1"))
        XCTAssertFalse(AppVersion.isNewer("2.0", than: "2.1.0"))
    }
}
