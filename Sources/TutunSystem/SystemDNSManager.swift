import Foundation
import SystemConfiguration
import TutunCore

/// DNS мака через туннель: пока работает TUN, у всех сетевых служб DNS — публичные адреса (по умолчанию 77.88.8.8
/// и 1.1.1.1). Маршрут к ним лежит через utun233, и sing-box отвечает сам (hijack-dns) — до настоящих серверов запрос
/// не доходит. Публичные, а не адрес внутри туннеля (как было в 2.11), по примеру Clash Verge Rev: если служба
/// упадёт и не вернёт настройку, у мака останется рабочий DNS, а не «нет интернета». Иначе системный DNS шёл к роутеру в локальной сети мимо туннеля,
/// и провайдер видел, какие сайты открываются. Исходные настройки сохраняются целиком и возвращаются при
/// отключении, падении туннеля без аварийной блокировки и при каждом старте службы (как системный прокси).
public final class SystemDNSManager {
    public static let defaultServers = ["77.88.8.8", "1.1.1.1"]
    private let snapshot: String
    public init(directory: String = Paths.runDir) { snapshot = directory + "/system-dns.plist" }

    public var isActive: Bool { FileManager.default.fileExists(atPath: snapshot) }

    public func enable(servers: [String] = SystemDNSManager.defaultServers) throws {
        try withPreferences { prefs, services in
            let saved: [String: [String: Any]]
            if isActive {
                saved = try readSnapshot()
            } else {
                var original: [String: [String: Any]] = [:]
                for service in services {
                    guard let id = SCNetworkServiceGetServiceID(service),
                          let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
                    original[id as String] = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                }
                let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
                try data.write(to: URL(fileURLWithPath: snapshot), options: .atomic)
                chmod(snapshot, 0o600)
                saved = original
            }
            for service in services {
                guard let id = SCNetworkServiceGetServiceID(service), let original = saved[id as String],
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
                guard SCNetworkProtocolSetConfiguration(proto, Self.tunnelConfiguration(over: original, servers: servers) as CFDictionary) else { throw failure() }
            }
            try commit(prefs)
        }
    }

    public func restore() throws {
        guard isActive else { return }
        let saved = try readSnapshot()
        try withPreferences { prefs, services in
            for service in services {
                guard let id = SCNetworkServiceGetServiceID(service), let config = saved[id as String],
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
                guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else { throw failure() }
            }
            try commit(prefs)
        }
        try FileManager.default.removeItem(atPath: snapshot)
    }

    /// Только адреса серверов: домены поиска и прочие параметры сети остаются как были.
    static func tunnelConfiguration(over original: [String: Any], servers: [String] = defaultServers) -> [String: Any] {
        var config = original
        config[kSCPropNetDNSServerAddresses as String] = servers.isEmpty ? defaultServers : servers
        return config
    }

    private func readSnapshot() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: snapshot))
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { throw failure() }
        return result
    }

    private func withPreferences(_ work: (SCPreferences, [SCNetworkService]) throws -> Void) throws {
        guard let prefs = SCPreferencesCreate(nil, "Tutun" as CFString, nil), SCPreferencesLock(prefs, false) else { throw failure() }
        defer { SCPreferencesUnlock(prefs) }
        let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
        guard !services.isEmpty else { throw failure() }
        try work(prefs, services)
    }

    private func commit(_ prefs: SCPreferences) throws {
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw failure() }
    }

    private func failure() -> Error {
        NSError(domain: "Tutun.DNS", code: Int(SCError()), userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить или восстановить системный DNS"])
    }
}
