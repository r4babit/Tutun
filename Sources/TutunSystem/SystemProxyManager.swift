import Foundation
import SystemConfiguration
import TutunCore

/// Хранит исходные настройки целиком, включая PAC, исключения и параметры авторизации.
public final class SystemProxyManager {
    private let snapshot = Paths.runDir + "/system-proxies.plist"
    public init() {}

    public func enable() throws {
        try withPreferences { prefs, services in
            let saved: [String: [String: Any]]
            if FileManager.default.fileExists(atPath: snapshot) {
                saved = try readSnapshot()
            } else {
                var original: [String: [String: Any]] = [:]
                for service in services {
                    guard let serviceID = SCNetworkServiceGetServiceID(service), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                    original[serviceID as String] = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                }
                let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
                try data.write(to: URL(fileURLWithPath: snapshot), options: .atomic)
                chmod(snapshot, 0o600)
                saved = original
            }
            for service in services {
                guard let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
                let id = serviceID as String
                guard let original = saved[id], let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                let config = Self.tutunConfiguration(over: original)
                guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else { throw failure() }
            }
            try commit(prefs)
        }
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: snapshot) else { return }
        let saved = try readSnapshot()
        try withPreferences { prefs, services in
            for service in services {
                guard let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
                let id = serviceID as String
                guard let config = saved[id], let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else { throw failure() }
            }
            try commit(prefs)
        }
        try FileManager.default.removeItem(atPath: snapshot)
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
        NSError(domain: "Tutun.Proxy", code: Int(SCError()), userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить или восстановить системный прокси"])
    }

    static func tutunConfiguration(over original: [String: Any]) -> [String: Any] {
        var config = original
        for (prefix, port) in [("HTTP", Paths.httpPort), ("HTTPS", Paths.httpPort), ("SOCKS", Paths.socksPort)] {
            config[prefix + "Enable"] = 1
            config[prefix + "Proxy"] = "127.0.0.1"
            config[prefix + "Port"] = port
        }
        config["ProxyAutoConfigEnable"] = 0
        config["ProxyAutoDiscoveryEnable"] = 0
        config["ExceptionsList"] = ["localhost", "127.0.0.1", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        return config
    }
}
