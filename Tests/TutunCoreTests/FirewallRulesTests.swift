import XCTest
@testable import TutunCore

final class FirewallRulesTests: XCTestCase {
    private func lines(_ policy: FirewallPolicy) -> [String] {
        FirewallRules.build(policy).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
    }

    /// Эталон: любое изменение правил должно быть осознанным — от них зависит, есть ли у мака интернет.
    func testRulesWhileConnecting() {
        XCTAssertEqual(lines(FirewallPolicy(dns: .systemResolver)), [
            "pass quick on lo0 all flags any no state",
            "pass quick on utun233 all flags any no state",
            "pass out quick proto { tcp, udp } all group _tutun flags any",
            "pass out quick inet proto udp from any port 68 to any port 67",
            "pass out quick inet6 proto udp from any port 546 to any port 547",
            "pass out quick inet6 proto icmp6 all icmp6-type { routersol, neighbrsol, neighbradv }",
            "pass out quick proto { tcp, udp } from any to any port 53 user _mdnsresponder flags any no state",
            "pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/24, 239.0.0.0/8, 255.255.255.255/32 } flags any no state",
            "pass out quick inet6 from any to { fe80::/10, fc00::/7, ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 } flags any no state",
            "block return out quick all",
        ])
    }

    func testConnectedBlocksDNSOutsideTunnelBeforeLAN() throws {
        let rules = lines(FirewallPolicy(dns: .tunnelOnly))
        let dns = try XCTUnwrap(rules.firstIndex(of: "block return out quick proto { tcp, udp } from any to any port 53"))
        let cores = try XCTUnwrap(rules.firstIndex { $0.contains("group _tutun") })
        let tunnel = try XCTUnwrap(rules.firstIndex { $0.contains("on utun233") })
        let lan = try XCTUnwrap(rules.firstIndex { $0.contains("192.168.0.0/16") })
        // DNS в туннеле и DNS ядер «в обход VPN» разрешены раньше запрета; роутер — позже, запросы на него не уйдут.
        XCTAssertLessThan(tunnel, dns); XCTAssertLessThan(cores, dns); XCTAssertLessThan(dns, lan)
        XCTAssertFalse(rules.contains { $0.contains("_mdnsresponder") })
    }

    func testLastRuleBlocksEverythingElse() {
        for dns in [FirewallPolicy.DNS.systemResolver, .tunnelOnly] {
            XCTAssertEqual(lines(FirewallPolicy(dns: dns, excludedRoutes: ["8.8.8.8"])).last, "block return out quick all")
        }
    }

    func testExcludedRoutesAreValidatedAndPassed() {
        let policy = FirewallPolicy(dns: .tunnelOnly, excludedRoutes: [
            "203.0.113.7", " 198.51.100.0/24 ", "2001:db8::/32", "203.0.113.7", "# заметка", "",
            "example.com", "1.2.3.4/33", "1.2.3.4; pass out quick all", "any", "{ 0.0.0.0/0 }",
        ])
        XCTAssertEqual(FirewallRules.exclusions(policy.excludedRoutes), ["203.0.113.7/32", "198.51.100.0/24", "2001:db8::/32"])
        let rules = lines(policy)
        XCTAssertTrue(rules.contains("pass out quick inet from any to 203.0.113.7/32 flags any no state"))
        XCTAssertTrue(rules.contains("pass out quick inet from any to 198.51.100.0/24 flags any no state"))
        XCTAssertTrue(rules.contains("pass out quick inet6 from any to 2001:db8::/32 flags any no state"))
        XCTAssertEqual(rules.filter { $0.hasPrefix("pass out quick") && $0.contains(" to ") && !$0.contains("{") && !$0.contains("port") }.count, 3)
    }

    /// Настоящий pfctl разбирает правила без загрузки в систему (-n): синтаксис и имена пользователей macOS.
    /// Группа _tutun есть только на маке с установленной службой 2.15+, поэтому в проверке её заменяет wheel.
    func testRealPfctlAcceptsRules() throws {
        let pfctl = "/sbin/pfctl"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: pfctl))
        for dns in [FirewallPolicy.DNS.systemResolver, .tunnelOnly] {
            let text = FirewallRules.build(FirewallPolicy(dns: dns, excludedRoutes: ["203.0.113.7", "2001:db8::/32"]))
                .replacingOccurrences(of: "group _tutun", with: "group wheel")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-pf-\(UUID()).conf")
            try text.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pfctl)
            p.arguments = ["-n", "-f", file.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, output)
            XCTAssertFalse(output.contains("syntax error"), output)
        }
    }
}
