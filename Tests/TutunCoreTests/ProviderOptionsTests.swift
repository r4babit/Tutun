import XCTest
@testable import TutunCore
import TutunShared

/// Заголовки и строки подписки в формате INCY/Happ (docs/COMPETITORS-2026-11-11.md).
final class ProviderOptionsTests: XCTestCase {
    func lookup(_ d: [String: String]) -> ProviderOptions.Lookup { { d[$0] } }

    func testBodyMetadataRoutingLinesAndServerDescription() throws {
        let note = Data("Германия · 10 Гбит".utf8).base64EncodedString()
        let body = """
        vless://11111111-2222-3333-4444-555555555555@de.example.net:443?security=tls#DE?serverDescription=\(note)
        #announce: Плановые работы завтра
        #profile-title: base64:\(Data("Мой VPN".utf8).base64EncodedString())
        #support-email: help@example.net
        #unknown-key: игнор
        ://autorouting/onadd/https://example.net/routing.json
        """
        let b = LinkParser.parseBatch(Data(body.utf8), subscriptionID: nil)
        XCTAssertEqual(b.servers.count, 1)
        XCTAssertEqual(b.servers[0].name, "DE")
        XCTAssertEqual(b.servers[0].note, "Германия · 10 Гбит")
        XCTAssertEqual(b.meta["announce"], "Плановые работы завтра")
        XCTAssertEqual(b.meta["support-email"], "help@example.net")
        XCTAssertNil(b.meta["unknown-key"])
        XCTAssertEqual(b.routingURLs, ["https://example.net/routing.json"])
        XCTAssertTrue(b.errors.isEmpty, "\(b.errors)")
        // Профиль маршрутов строкой без схемы — в формате INCY.
        let profile = Data(#"{"Name":"P","DirectSites":["geosite:category-ru"]}"#.utf8).base64EncodedString()
        let b2 = LinkParser.parseBatch(Data("://routing/onadd/\(profile)\nincy://routing/add/\(profile)".utf8), subscriptionID: nil)
        XCTAssertEqual(b2.profiles.map(\.name), ["P", "P"])
        // Подпись длиннее 30 символов обрезается; имя без подписи не меняется.
        XCTAssertEqual(LinkParser.splitServerDescription("A?serverDescription=" + String(repeating: "x", count: 40)).1?.count, 30)
        XCTAssertEqual(LinkParser.splitServerDescription("Просто имя").0, "Просто имя")
    }

    func testFragmentationAndNoisesAreValidated() {
        let f = ProviderOptions.fragment(lookup(["fragmentation-enable": "1", "fragmentation-packets": "1-3", "fragmentation-length": "50-100", "fragmentation-interval": "5-10"]))
        XCTAssertEqual(f, ProviderFragment(packets: "1-3", length: "50-100", interval: "5-10"))
        XCTAssertNil(ProviderOptions.fragment(lookup(["fragmentation-enable": "0", "fragmentation-packets": "tlshello"])))
        XCTAssertNil(ProviderOptions.fragment(lookup(["fragmentation-enable": "1", "fragmentation-packets": "rm -rf"])))
        // Мусор в длине — значение по умолчанию, а не мусор в конфиге.
        XCTAssertEqual(ProviderOptions.fragment(lookup(["fragmentation-enable": "true", "fragmentation-length": "a-b"]))?.length, "100-200")
        XCTAssertEqual(ProviderOptions.noises(lookup(["noises-enable": "1", "noises-type": "hex", "noises-packet": "deadBEEF", "noises-delay": "5-9"])),
                       ProviderNoises(type: "hex", packet: "deadBEEF", delay: "5-9"))
        XCTAssertNil(ProviderOptions.noises(lookup(["noises-enable": "1", "noises-type": "hex", "noises-packet": "не hex"])))
        XCTAssertNil(ProviderOptions.noises(lookup(["noises-enable": "1", "noises-type": "exec"])))
        XCTAssertNil(ProviderOptions.noises(lookup(["noises-enable": "1", "noises-type": "rand", "noises-packet": "много"])))
    }

    func testServerResolveAndMigrationRequireHttps() throws {
        XCTAssertEqual(ProviderOptions.serverResolve(lookup(["server-address-resolve-enable": "1",
                                                              "server-address-resolve-dns-domain": "https://common.dot.dns.yandex.net/dns-query",
                                                              "server-address-resolve-dns-ip": "77.88.8.8"])),
                       ServerResolve(dohURL: "https://common.dot.dns.yandex.net/dns-query", bootstrapIP: "77.88.8.8"))
        XCTAssertNil(ProviderOptions.serverResolve(lookup(["server-address-resolve-enable": "1", "server-address-resolve-dns-domain": "http://x.example/dns-query", "server-address-resolve-dns-ip": "1.1.1.1"])))
        XCTAssertNil(ProviderOptions.serverResolve(lookup(["server-address-resolve-enable": "1", "server-address-resolve-dns-domain": "https://x.example/dns-query", "server-address-resolve-dns-ip": "x.example"])))

        let current = try XCTUnwrap(URL(string: "https://old.example.com/sub/abc?x=1"))
        XCTAssertEqual(ProviderOptions.migration(from: current, lookup(["new-domain": "new.example.org"])), "https://new.example.org/sub/abc?x=1")
        XCTAssertEqual(ProviderOptions.migration(from: current, lookup(["new-url": "https://other.example/s/1", "new-domain": "new.example.org"])), "https://other.example/s/1")
        XCTAssertNil(ProviderOptions.migration(from: current, lookup(["new-url": "http://other.example/s/1"])))
        XCTAssertNil(ProviderOptions.migration(from: current, lookup(["new-domain": "bad domain/../x"])))
        XCTAssertNil(ProviderOptions.migration(from: current, lookup(["new-domain": "old.example.com"])))
        XCTAssertEqual(ProviderOptions.filename(#"attachment; filename="My VPN.txt""#), "My VPN")
        XCTAssertEqual(ProviderOptions.filename("attachment; filename*=UTF-8''%D0%9C%D0%BE%D0%B9.txt"), "Мой")
    }

    func testDeviceIDIsStableUppercaseUUIDAndHidesHardwareID() {
        let a = ProviderOptions.deviceID(fromHardwareUUID: "12345678-ABCD-ABCD-ABCD-1234567890AB")
        XCTAssertEqual(a, ProviderOptions.deviceID(fromHardwareUUID: "12345678-abcd-abcd-abcd-1234567890ab"))
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertEqual(a, a.uppercased())
        XCTAssertFalse(a.contains("1234567890AB"))
        XCTAssertNotEqual(a, ProviderOptions.deviceID(fromHardwareUUID: "00000000-0000-0000-0000-000000000000"))
    }

    func testProviderDoHForServerAddressesInTunnelDNS() throws {
        var named = try LinkParser.parse("vless://11111111-2222-3333-4444-555555555555@vpn.example.net:443?security=tls#V")
        named.host = "vpn.example.net"
        let r = ServerResolve(dohURL: "https://common.dot.dns.yandex.net/dns-query", bootstrapIP: "77.88.8.8")
        let input = ConfigBuilder.Input(servers: [named], settings: AppSettings(), serverResolve: r)
        XCTAssertNoThrow(try ConnectionValidation.validate(input))
        let sb = try JSONSerialization.jsonObject(with: Data(ConfigBuilder.build(input).singBox!.utf8)) as! [String: Any]
        let dns = sb["dns"] as! [String: Any]
        let doh = try XCTUnwrap((dns["servers"] as! [[String: Any]]).first { $0["tag"] as? String == "server-resolve" })
        XCTAssertEqual(doh["server"] as? String, "77.88.8.8")
        XCTAssertEqual((doh["tls"] as? [String: Any])?["server_name"] as? String, "common.dot.dns.yandex.net")
        XCTAssertEqual(doh["path"] as? String, "/dns-query")
        let rule = try XCTUnwrap((dns["rules"] as! [[String: Any]]).first { ($0["domain"] as? [String]) == ["vpn.example.net"] })
        XCTAssertEqual(rule["server"] as? String, "server-resolve")
        // Настоящие ядра должны принять DoH провайдера (sing-box) и шум (xray).
        var withNoise = input; withNoise.settings.noises = true; withNoise.settings.noisesType = "hex"; withNoise.settings.noisesPacket = "deadbeef"
        try TutunCoreTests().checkWithCores(ConfigBuilder.build(withNoise))
        var bad = input; bad.serverResolve = ServerResolve(dohURL: "file:///etc/hosts", bootstrapIP: "77.88.8.8")
        XCTAssertThrowsError(try ConnectionValidation.validate(bad))
        var noisy = input; noisy.settings.noisesType = "exec"
        XCTAssertThrowsError(try ConnectionValidation.validate(noisy))
    }
}
