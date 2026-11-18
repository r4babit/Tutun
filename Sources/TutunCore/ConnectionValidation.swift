import Foundation
import TutunShared

public enum ConnectionValidation {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public static func httpURL(_ text: String) -> Bool {
        guard let u = URL(string: text), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty else { return false }
        return true
    }

    public static func validate(_ input: ConfigBuilder.Input) throws {
        guard (1...25).contains(input.servers.count) else { throw Failure(tr("Нужно от 1 до 25 серверов")) }
        let s = input.settings
        let ruleLists = s.directDomains + s.proxyDomains + s.blockDomains + s.directIPs + s.proxyIPs + s.blockIPs
            + (input.profile?.directSites ?? []) + (input.profile?.proxySites ?? []) + (input.profile?.blockSites ?? [])
            + (input.profile?.directIPs ?? []) + (input.profile?.proxyIPs ?? []) + (input.profile?.blockIPs ?? [])
        guard !ruleLists.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("ext:") }) else {
            throw Failure(tr("Внешние файлы правил недопустимы в конфиге службы"))
        }
        if let r = input.serverResolve {
            guard ProviderOptions.httpsURL(r.dohURL) != nil, ProviderOptions.ipAddress(r.bootstrapIP) != nil else {
                throw Failure(tr("Недопустимые параметры подключения"))
            }
        }
        guard ["rand", "str", "hex"].contains(s.noisesType), !s.noisesPacket.isEmpty, s.noisesPacket.count <= 512,
              ProviderOptions.range(s.noisesDelay) != nil else { throw Failure(tr("Недопустимые параметры подключения")) }
        guard DirectCountry.codes.contains(s.directCountry) else { throw Failure(tr("Неизвестная страна для правил «напрямую»")) }
        guard (10...300).contains(s.probeIntervalSec), (1...10).contains(s.healthFailLimit),
              (2...30).contains(s.testTimeout), (1...128).contains(s.muxConcurrency), httpURL(s.testURL),
              ["debug", "info", "warning", "error", "none"].contains(s.logLevel) else {
            throw Failure(tr("Недопустимые параметры подключения"))
        }
        if s.allowLAN {
            // Без пароля VPN раздаётся всем в той же сети, например в кафе или гостинице.
            guard !s.lanUser.trimmingCharacters(in: .whitespaces).isEmpty, !s.lanPassword.isEmpty else {
                throw Failure(tr("Для раздачи в локальную сеть задайте логин и пароль"))
            }
            let reserved = Set([Paths.socksPort, Paths.httpPort, Paths.healthPort, Paths.apiPort, Paths.clashPort] + Array(Paths.helperBasePort..<(Paths.helperBasePort + 25)) + Array(Paths.probeBasePort..<(Paths.probeBasePort + 25)))
            guard (1025...65000).contains(s.lanSocksPort), (1025...65000).contains(s.lanHttpPort),
                  s.lanSocksPort != s.lanHttpPort, !reserved.contains(s.lanSocksPort), !reserved.contains(s.lanHttpPort) else {
                throw Failure(tr("Порты локальной сети совпадают или заняты Tutun"))
            }
        }
        for server in input.servers + (input.chain.map { [$0] } ?? []) {
            let outbound = server.outbound
            let proto = (outbound["protocol"] ?? outbound["type"]) as? String ?? ""
            let allowed: Set<String> = server.engine == .xray
                ? ["vless", "vmess", "trojan", "shadowsocks", "hysteria", "wireguard", "socks"]
                : ["hysteria2", "tuic"]
            guard allowed.contains(proto), !containsFileReference(outbound) else {
                throw Failure(tr("Недопустимый протокол или доступ к файлам в конфиге сервера"))
            }
        }
    }

    // Клиентский конфиг не должен заставлять root-ядро читать файлы или Unix-сокеты.
    private static func containsFileReference(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, item) in dict {
                let k = key.lowercased()
                if k.hasSuffix("file") || k.hasSuffix("filepath") || k.hasSuffix("_path") ||
                    ["directory", "masterkeylog", "keylog", "keylogpath", "dssettings", "acme"].contains(k) { return true }
                if ["address", "server", "endpoint"].contains(k), let text = item as? String,
                   text.hasPrefix("/") || text.hasPrefix("@") || text.hasPrefix("file:") || text.hasPrefix("unix:") { return true }
                if containsFileReference(item) { return true }
            }
        } else if let list = value as? [Any] { return list.contains(where: containsFileReference) }
        return false
    }
}
