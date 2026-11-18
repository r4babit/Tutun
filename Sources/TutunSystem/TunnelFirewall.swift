import Foundation
import TutunCore

/// Блокировка трафика вне VPN через PF. Правила (FirewallRules) стоят всё время, пока VPN включён, в собственном
/// anchor `com.apple/tutun`; основной набор правил PF не меняется. До службы 2.15 правило ставилось только после
/// обнаружения потери TUN (EmergencyFirewall) — между аварией и обнаружением оставалось окно.
public final class TunnelFirewall {
    public typealias Runner = (String, [String]) -> (Int32, String)
    private let anchor = FirewallRules.anchor
    private let rulePath: String
    private let legacyRulePath: String
    private let tokenPath: String
    private let bootPath: String
    private let run: Runner
    private let log: (String) -> Void
    private let groupExists: () -> Bool
    /// Какие правила загружены этим процессом; nil — не загружал (после перезапуска службы ставим заново).
    public private(set) var applied: FirewallPolicy?

    public init(directory: String = Paths.runDir, run: @escaping Runner, log: @escaping (String) -> Void,
                groupExists: @escaping () -> Bool = { getgrnam(FirewallRules.group) != nil }) {
        rulePath = directory + "/tunnel.pf"
        legacyRulePath = directory + "/emergency.pf"
        tokenPath = directory + "/pf-token"
        bootPath = directory + "/pf-boot"
        self.run = run; self.log = log; self.groupExists = groupExists
    }

    public var isActive: Bool { applied != nil }

    private func bootSession() throws -> String {
        let (code, text) = run("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        guard code == 0, !text.isEmpty else { throw failure("Не определить текущую загрузку macOS") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Проверка до любых изменений: без группы ядер правила отрезали бы от сети и сам VPN.
    public func prepare() throws {
        guard groupExists() else {
            throw failure("Нет группы \(FirewallRules.group) для ядер — переустановите службу в «О Tutun»")
        }
        let (code, rules) = run("/sbin/pfctl", ["-sr"])
        guard code == 0, rules.contains("anchor \"com.apple/*\"") else {
            throw failure("Не найден системный anchor com.apple/* для блокировки трафика вне VPN")
        }
    }

    public func apply(_ policy: FirewallPolicy) throws {
        guard applied != policy else { return }
        try prepare()
        let boot = try bootSession()
        if (try? String(contentsOfFile: bootPath, encoding: .utf8)) != boot {
            // Reference PF действителен только до перезагрузки системы.
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        try FirewallRules.build(policy).write(toFile: rulePath, atomically: true, encoding: .utf8)
        chmod(rulePath, 0o600)
        // Набор в anchor заменяется целиком одной операцией: промежутка без правил нет.
        let (loadCode, loadOutput) = run("/sbin/pfctl", ["-a", anchor, "-f", rulePath])
        guard loadCode == 0 else {
            throw failure("Не загрузить правила блокировки PF: " + (loadOutput.split(separator: "\n").last.map(String.init) ?? "код \(loadCode)"))
        }
        let first = applied == nil
        if !FileManager.default.fileExists(atPath: tokenPath) {
            let (enableCode, output) = run("/sbin/pfctl", ["-E"])
            guard enableCode == 0,
                  let line = output.split(separator: "\n").first(where: { $0.contains("Token :") }),
                  let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  UInt64(token) != nil else { throw failure("Не включить PF для блокировки трафика вне VPN") }
            try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
            chmod(tokenPath, 0o600)
            try boot.write(toFile: bootPath, atomically: true, encoding: .utf8)
            chmod(bootPath, 0o600)
        }
        if first {
            // Соединения, установленные до включения правил, не должны их обходить.
            for network in ["0.0.0.0/0", "::/0"] {
                let (code, _) = run("/sbin/pfctl", ["-k", network])
                guard code == 0 else { throw failure("Не сбросить прежние соединения для блокировки") }
            }
            log("Блокировка трафика вне VPN включена")
        }
        applied = policy
    }

    public func release() throws {
        let fm = FileManager.default
        guard applied != nil || fm.fileExists(atPath: tokenPath) || fm.fileExists(atPath: rulePath) || fm.fileExists(atPath: legacyRulePath) else { return }
        let (code, _) = run("/sbin/pfctl", ["-a", anchor, "-F", "rules"])
        guard code == 0 else { throw failure("Не убрать блокировку PF") }
        applied = nil
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), UInt64(token) != nil,
           (try? String(contentsOfFile: bootPath, encoding: .utf8)) == (try bootSession()) {
            // Освобождаем только собственный reference, не выключаем чужой firewall.
            let (releaseCode, _) = run("/sbin/pfctl", ["-X", token])
            guard releaseCode == 0 else { throw failure("Не освободить reference PF") }
        }
        for path in [tokenPath, bootPath, rulePath, legacyRulePath] { try? fm.removeItem(atPath: path) }
        log("Блокировка трафика вне VPN снята")
    }

    private func failure(_ text: String) -> Error {
        NSError(domain: "Tutun.Firewall", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
