import Foundation
import TutunShared

/// Что провайдер может настроить заголовками подписки (как у INCY/Happ, docs/COMPETITORS-2026-11-11.md).
/// Всё проверяется здесь, на входе: дальше по коду значениям доверяем.
public enum ProviderOptions {
    public typealias Lookup = (String) -> String?

    static func flag(_ v: String?) -> Bool {
        ["1", "true", "yes", "on"].contains(v?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
    }

    static func range(_ v: String?) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespaces), t.range(of: #"^\d{1,5}(-\d{1,5})?$"#, options: .regularExpression) != nil else { return nil }
        return t
    }

    static func ipAddress(_ v: String?) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespaces) else { return nil }
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, t, &a4) == 1 || inet_pton(AF_INET6, t, &a6) == 1 ? t : nil
    }

    public static func httpsURL(_ v: String?) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespaces), let u = URL(string: t),
              u.scheme?.lowercased() == "https", !(u.host ?? "").isEmpty else { return nil }
        return t
    }

    /// `fragmentation-enable: 1` + packets (`tlshello`/`all`/`1-3`), length и interval (`min-max`).
    public static func fragment(_ h: Lookup) -> ProviderFragment? {
        guard flag(h("fragmentation-enable")) else { return nil }
        let packets = h("fragmentation-packets")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "tlshello"
        guard packets == "tlshello" || packets == "all" || range(packets) != nil else { return nil }
        return ProviderFragment(packets: packets, length: range(h("fragmentation-length")) ?? "100-200",
                                interval: range(h("fragmentation-interval")) ?? "10-20")
    }

    /// `noises-enable: 1` + type (`rand`/`str`/`hex`), packet и delay (`min-max` мс).
    public static func noises(_ h: Lookup) -> ProviderNoises? {
        guard flag(h("noises-enable")) else { return nil }
        let type = h("noises-type")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "rand"
        guard ["rand", "str", "hex"].contains(type) else { return nil }
        let packet = h("noises-packet")?.trimmingCharacters(in: .whitespaces) ?? "10-20"
        let packetOK: Bool
        switch type {
        case "rand": packetOK = range(packet) != nil
        case "hex": packetOK = packet.count <= 512 && packet.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        default: packetOK = !packet.isEmpty && packet.count <= 256
        }
        guard packetOK else { return nil }
        return ProviderNoises(type: type, packet: packet, delay: range(h("noises-delay")) ?? "10-16")
    }

    /// `server-address-resolve-enable: 1` + DoH-адрес (https) и IP, по которому к нему подключаться.
    public static func serverResolve(_ h: Lookup) -> ServerResolve? {
        guard flag(h("server-address-resolve-enable")), let url = httpsURL(h("server-address-resolve-dns-domain")),
              let ip = ipAddress(h("server-address-resolve-dns-ip")) else { return nil }
        return ServerResolve(dohURL: url, bootstrapIP: ip)
    }

    /// Новый адрес подписки: `new-url` (весь адрес, https) важнее `new-domain` (только имя сервера).
    public static func migration(from current: URL, _ h: Lookup) -> String? {
        if let u = httpsURL(h("new-url")) { return u == current.absoluteString ? nil : u }
        guard let domain = h("new-domain")?.trimmingCharacters(in: .whitespaces).lowercased(),
              domain.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              domain != current.host?.lowercased(),
              var c = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
        c.host = domain; c.scheme = "https"
        return c.url?.absoluteString
    }

    /// Имя из `content-disposition: attachment; filename="My VPN.txt"` (без расширения).
    public static func filename(_ disposition: String?) -> String? {
        guard let d = disposition, let r = d.range(of: #"filename\*?=(UTF-8'')?"?([^";]+)"?"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var v = String(d[r]).replacingOccurrences(of: #"^filename\*?=(UTF-8'')?"?"#, with: "", options: [.regularExpression, .caseInsensitive])
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        v = (v.removingPercentEncoding ?? v)
        if let dot = v.lastIndex(of: "."), v.distance(from: dot, to: v.endIndex) <= 5 { v = String(v[..<dot]) }
        return v.isEmpty ? nil : v
    }

    /// Устойчивый ID устройства, как ждут панели провайдеров (UUID в верхнем регистре из SHA-256),
    /// одинаковый после переустановки. Аппаратный идентификатор в открытом виде наружу не уходит — только хеш.
    public static func deviceID(fromHardwareUUID hardware: String) -> String {
        let digest = SHA256Hex.hash("tutun_hwid_" + hardware.uppercased())
        let h = Array(digest.prefix(32))
        func part(_ a: Int, _ b: Int) -> String { String(h[a..<b]) }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-").uppercased()
    }
}

import CryptoKit
enum SHA256Hex {
    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
