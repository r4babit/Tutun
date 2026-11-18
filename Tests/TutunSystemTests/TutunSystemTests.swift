import XCTest
@testable import TutunSystem
import TutunCore

final class TutunSystemTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-system-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func firewall(_ dir: URL, group: Bool = true, calls: @escaping ([String]) -> Void) -> TunnelFirewall {
        TunnelFirewall(directory: dir.path, run: { executable, args in
            calls([executable] + args)
            if args == ["-sr"] { return (0, "anchor \"com.apple/*\" all") }
            if args == ["-n", "kern.boottime"] { return (0, "test-boot") }
            if args == ["-E"] { return (0, "pf enabled\nToken : 42\n") }
            return (0, "")
        }, log: { _ in }, groupExists: { group })
    }

    func testFirewallAppliesAndReleasesOnlyItsOwnAnchor() throws {
        let dir = try directory()
        var calls: [[String]] = []
        let firewall = firewall(dir) { calls.append($0) }
        try firewall.apply(FirewallPolicy(dns: .systemResolver))
        let rulePath = dir.appendingPathComponent("tunnel.pf")
        XCTAssertEqual(try String(contentsOf: rulePath, encoding: .utf8), FirewallRules.build(FirewallPolicy(dns: .systemResolver)))
        XCTAssertTrue(calls.contains(["/sbin/pfctl", "-a", "com.apple/tutun", "-f", rulePath.path]))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("pf-token").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try firewall.release()
        XCTAssertTrue(calls.contains(["/sbin/pfctl", "-a", "com.apple/tutun", "-F", "rules"]))
        XCTAssertTrue(calls.contains(["/sbin/pfctl", "-X", "42"]))
        XCTAssertFalse(calls.contains { $0.contains("-d") || $0 == ["/sbin/pfctl", "-F", "all"] })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pf-token").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulePath.path))
    }

    /// Смена правила DNS при поднятом туннеле не должна рвать соединения: сброс и включение PF — только в первый раз.
    func testFirewallSwitchesPolicyWithoutResettingConnections() throws {
        let dir = try directory()
        var calls: [[String]] = []
        let firewall = firewall(dir) { calls.append($0) }
        try firewall.apply(FirewallPolicy(dns: .systemResolver))
        XCTAssertEqual(calls.filter { $0.contains("-k") }.count, 2)
        XCTAssertEqual(calls.filter { $0.contains("-E") }.count, 1)
        calls = []
        try firewall.apply(FirewallPolicy(dns: .tunnelOnly))
        XCTAssertEqual(calls.filter { $0.contains("-f") }.count, 1)
        XCTAssertFalse(calls.contains { $0.contains("-k") || $0.contains("-E") })
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("tunnel.pf"), encoding: .utf8).contains("port 53"))
        calls = []
        try firewall.apply(FirewallPolicy(dns: .tunnelOnly))
        XCTAssertTrue(calls.isEmpty)
    }

    func testFirewallRefusesMissingAnchorBeforeChangingRules() throws {
        let dir = try directory()
        var calls: [[String]] = []
        let firewall = TunnelFirewall(directory: dir.path, run: { _, args in
            calls.append(args); return (0, "")
        }, log: { _ in }, groupExists: { true })
        XCTAssertThrowsError(try firewall.apply(FirewallPolicy(dns: .systemResolver)))
        XCTAssertEqual(calls, [["-sr"]])
        XCTAssertFalse(firewall.isActive)
    }

    /// Без группы ядер правила отрезали бы от сети и сам VPN — отказываемся до любых команд.
    func testFirewallRefusesWithoutCoreGroup() throws {
        let dir = try directory()
        var calls: [[String]] = []
        let firewall = firewall(dir, group: false) { calls.append($0) }
        XCTAssertThrowsError(try firewall.apply(FirewallPolicy(dns: .systemResolver)))
        XCTAssertTrue(calls.isEmpty)
    }

    func testFirewallDoesNotReleaseReferenceFromPreviousBoot() throws {
        let dir = try directory()
        try "old-boot".write(to: dir.appendingPathComponent("pf-boot"), atomically: true, encoding: .utf8)
        try "999".write(to: dir.appendingPathComponent("pf-token"), atomically: true, encoding: .utf8)
        var calls: [[String]] = []
        let firewall = TunnelFirewall(directory: dir.path, run: { _, args in
            calls.append(args)
            return (0, args == ["-n", "kern.boottime"] ? "new-boot" : "")
        }, log: { _ in }, groupExists: { true })
        try firewall.release()
        XCTAssertFalse(calls.contains(["-X", "999"]))
    }

    /// Правило службы 2.14 и старше (emergency.pf) убирается новой службой.
    func testFirewallReleasesRulesLeftByOlderService() throws {
        let dir = try directory()
        try "block drop out quick on ! lo0 all\n".write(to: dir.appendingPathComponent("emergency.pf"), atomically: true, encoding: .utf8)
        var calls: [[String]] = []
        let firewall = firewall(dir) { calls.append($0) }
        try firewall.release()
        XCTAssertTrue(calls.contains(["/sbin/pfctl", "-a", "com.apple/tutun", "-F", "rules"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("emergency.pf").path))
    }

    func testTunnelDNSReplacesOnlyServerAddresses() throws {
        let original: [String: Any] = ["ServerAddresses": ["192.168.1.1"], "SearchDomains": ["home.lan"], "DomainName": "home.lan"]
        let temporary = SystemDNSManager.tunnelConfiguration(over: original)
        XCTAssertEqual(temporary["ServerAddresses"] as? [String], ["77.88.8.8", "1.1.1.1"])
        XCTAssertEqual(temporary["SearchDomains"] as? [String], ["home.lan"])
        XCTAssertEqual(temporary["DomainName"] as? String, "home.lan")
        XCTAssertEqual(original["ServerAddresses"] as? [String], ["192.168.1.1"])
        // DNS от роутера по DHCP — пустая ручная настройка; её же и вернём.
        XCTAssertEqual(SystemDNSManager.tunnelConfiguration(over: [:], servers: ["8.8.8.8", "1.1.1.1"])["ServerAddresses"] as? [String], ["8.8.8.8", "1.1.1.1"])
        // Заглушки — только публичные адреса: настройка, оставшаяся после сбоя, не должна лишать мак DNS.
        XCTAssertFalse(SystemDNSManager.defaultServers.contains { $0.hasPrefix("172.") || $0.hasPrefix("10.") || $0.hasPrefix("192.168.") })
    }

    func testTemporaryProxyConfigurationPreservesOriginalSnapshot() throws {
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "corporate.example", "HTTPPort": 3128,
                                       "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example/pac",
                                       "ExceptionsList": ["internal.example"], "SOCKSEnable": 0]
        let snapshot = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let temporary = SystemProxyManager.tutunConfiguration(over: original)
        XCTAssertEqual(temporary["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(temporary["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertEqual(temporary["ProxyAutoConfigURLString"] as? String, "https://example/pac")
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: snapshot, format: nil) as? NSDictionary)
        XCTAssertEqual(restored, original as NSDictionary)
        XCTAssertEqual(original["HTTPProxy"] as? String, "corporate.example")
        XCTAssertEqual(original["ExceptionsList"] as? [String], ["internal.example"])
    }
}
