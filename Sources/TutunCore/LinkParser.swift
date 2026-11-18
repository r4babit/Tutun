import Foundation
import TutunShared
import CryptoKit

public enum LinkError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case malformed(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return tr("не поддерживается: \(s)")
        case .malformed(let s): return tr("ссылка повреждена: \(s)")
        }
    }
}

public struct ParsedBatch: Sendable {
    public var servers: [Server] = []
    public var profiles: [RoutingProfile] = []
    public var errors: [String] = []
    /// Метаданные из тела подписки: строки «#announce: …», «#profile-title: …» и т.п. (ключ — в нижнем регистре).
    public var meta: [String: String] = [:]
    /// Профили маршрутов по ссылке из тела: «://autorouting/onadd/https://…», «://routing/onadd/https://…».
    public var routingURLs: [String] = []
}

/// Разбор ссылок vless/vmess/trojan/ss/hysteria2/tuic/wireguard/socks.
/// Сервер получает готовый outbound: для xray или (TUIC, Hysteria2 с obfs/insecure) для вспомогательного sing-box.
public enum LinkParser {
    public static func parse(_ raw: String, subscriptionID: UUID? = nil) throws -> Server {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = link.range(of: "://") else { throw LinkError.malformed(tr("нет схемы")) }
        let scheme = link[..<schemeEnd.lowerBound].lowercased()
        var server: Server
        switch scheme {
        case "vless": server = try parseStd(link, proto: "vless")
        case "trojan": server = try parseStd(link, proto: "trojan")
        case "vmess": server = try parseVmess(link)
        case "ss": server = try parseSS(link)
        case "hysteria2", "hy2": server = try parseHy2(link)
        case "tuic": server = try parseTUIC(link)
        case "wireguard", "wg": server = try parseWireGuard(link)
        case "socks", "socks5": server = try parseSocks(link)
        case "awg", "amneziawg": throw LinkError.unsupported(tr("AmneziaWG (его не умеет ни xray, ни sing-box)"))
        case "happ" where link.lowercased().hasPrefix("happ://crypt"):
            throw LinkError.unsupported(tr("зашифрованная ссылка Happ — открывается только в Happ"))
        default: throw LinkError.unsupported(String(scheme))
        }
        server.id = stableID(link)
        server.subscriptionID = subscriptionID
        server.rawLink = link
        if let name = server.name.removingPercentEncoding { server.name = name }
        (server.name, server.note) = splitServerDescription(server.name)
        return server
    }

    /// «Имя?serverDescription=base64» → имя и подпись (как у INCY). Подпись — до 30 символов.
    static func splitServerDescription(_ name: String) -> (String, String?) {
        guard let r = name.range(of: "?serverDescription=", options: .caseInsensitive) else { return (name, nil) }
        let raw = String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let text = (base64Decode(raw) ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? name : clean, text.isEmpty ? nil : String(text.prefix(30)))
    }

    /// Метаданные, которые провайдер может прислать строками в теле подписки.
    static let bodyMetaKeys: Set<String> = ["announce", "profile-title", "support-url", "profile-web-page-url", "announce-url",
                                            "profile-update-interval", "profile-description", "support-email", "subscription-name"]

    /// Тело подписки или вставленный текст: base64-список, ссылки построчно, JSON с конфигами xray, профили маршрутов.
    public static func parseBatch(_ data: Data, subscriptionID: UUID?) -> ParsedBatch {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), !text.hasPrefix("["), !text.hasPrefix("{"), !text.contains("[Interface]"),
           let decoded = base64Decode(text) {
            text = decoded
        }
        if text.contains("[Interface]") && text.contains("[Peer]") {
            do { return ParsedBatch(servers: [try parseWireGuardConf(text, name: "WireGuard")]) }
            catch { return ParsedBatch(errors: ["WireGuard: \(error.localizedDescription)"]) }
        }
        if text.hasPrefix("[") || text.hasPrefix("{") {
            let r = parseJSONConfigs(Data(text.utf8), subscriptionID: subscriptionID)
            return ParsedBatch(servers: r.servers, errors: r.errors)
        }
        var out = ParsedBatch()
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("//") else { continue }
            if l.hasPrefix("#") {
                // «#announce: текст» — метаданные провайдера в теле (заголовки HTTP важнее, см. SubscriptionFetcher).
                if let colon = l.firstIndex(of: ":") {
                    let key = l[l.index(after: l.startIndex)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if bodyMetaKeys.contains(key), !value.isEmpty, out.meta[key] == nil { out.meta[key] = value }
                }
                continue
            }
            // Строки маршрутов в формате INCY/Happ, со схемой или без: «://autorouting/onadd/…», «://routing/onadd/…», «://onadd/…».
            if let r = l.range(of: #"^[a-z]*://(autorouting/(on)?add|routing/(on)?add|routing|onadd)/"#, options: [.regularExpression, .caseInsensitive]) {
                let payload = String(l[r.upperBound...])
                if payload.lowercased().hasPrefix("https://") { out.routingURLs.append(payload); continue }
                if var p = RoutingProfiles.parseLink("happ://routing/onadd/" + payload) { p.fromSubscription = subscriptionID; out.profiles.append(p) }
                continue
            }
            if let p = RoutingProfiles.parseLink(l) { var p = p; p.fromSubscription = subscriptionID; out.profiles.append(p); continue }
            if l.lowercased().hasPrefix("happ://add/") || l.lowercased().hasPrefix("tutun://add/") { continue }
            do { out.servers.append(try parse(l, subscriptionID: subscriptionID)) }
            catch {
                let name = l.firstIndex(of: "#").map { String(l[l.index(after: $0)...]).removingPercentEncoding ?? "" } ?? String(l.prefix(16))
                out.errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Совместимость со старым именем.
    public static func parseSubscriptionBody(_ data: Data, subscriptionID: UUID?) -> (servers: [Server], errors: [String]) {
        let b = parseBatch(data, subscriptionID: subscriptionID); return (b.servers, b.errors)
    }

    static func parseJSONConfigs(_ data: Data, subscriptionID: UUID?) -> (servers: [Server], errors: [String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return ([], [tr("JSON не читается")]) }
        let configs: [[String: Any]] = (obj as? [[String: Any]]) ?? [(obj as? [String: Any]) ?? [:]]
        var servers: [Server] = [], errors: [String] = []
        let skip: Set<String> = ["freedom", "blackhole", "dns", "loopback"]
        for (i, cfg) in configs.enumerated() {
            let outs = cfg["outbounds"] as? [[String: Any]] ?? []
            let candidates = outs.filter { !skip.contains(($0["protocol"] as? String) ?? "") }
            guard var ob = candidates.first(where: { ($0["tag"] as? String) == "proxy" }) ?? candidates.first else {
                errors.append(tr("конфиг \(i + 1): нет сервера")); continue
            }
            ob.removeValue(forKey: "tag")
            if var ss = ob["streamSettings"] as? [String: Any], var so = ss["sockopt"] as? [String: Any] {
                so.removeValue(forKey: "dialerProxy"); ss["sockopt"] = so; ob["streamSettings"] = ss
            }
            let (host, port) = endpoint(of: ob)
            let name = (cfg["remarks"] as? String) ?? tr("Сервер \(i + 1)")
            let net = (ob["streamSettings"] as? [String: Any])?["network"] as? String ?? "tcp"
            let json = toJSON(ob)
            servers.append(Server(id: stableID(json), name: name, proto: (ob["protocol"] as? String) ?? "?",
                                  host: host, port: port, transport: net, outboundJSON: json,
                                  subscriptionID: subscriptionID))
        }
        return (servers, errors)
    }

    public static func endpoint(of ob: [String: Any]) -> (String, Int) {
        let s = ob["settings"] as? [String: Any] ?? [:]
        if let v = (s["vnext"] as? [[String: Any]])?.first ?? (s["servers"] as? [[String: Any]])?.first {
            return ((v["address"] as? String) ?? "", (v["port"] as? Int) ?? 0)
        }
        return ((s["address"] as? String) ?? "", (s["port"] as? Int) ?? 0)
    }

    // MARK: vless / trojan

    static func query(_ comps: URLComponents) -> [String: String] {
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return q
    }

    static func parseStd(_ link: String, proto: String) throws -> Server {
        guard let comps = URLComponents(string: link), let host = comps.host, let port = comps.port else {
            throw LinkError.malformed(proto)
        }
        let cred = (comps.percentEncodedUser ?? "").removingPercentEncoding ?? ""
        guard !cred.isEmpty else { throw LinkError.malformed(tr("\(proto): нет ключа")) }
        let q = query(comps)
        let addr = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        var ob: [String: Any] = ["protocol": proto]
        if proto == "vless" {
            var user: [String: Any] = ["id": cred, "encryption": q["encryption"].flatMap { $0.isEmpty ? nil : $0 } ?? "none"]
            if let flow = q["flow"], !flow.isEmpty { user["flow"] = flow }
            ob["settings"] = ["vnext": [["address": addr, "port": port, "users": [user]]]]
        } else {
            ob["settings"] = ["servers": [["address": addr, "port": port, "password": cred]]]
        }
        let net = normalizeNetwork(q["type"] ?? "tcp")
        ob["streamSettings"] = streamSettings(network: net, security: q["security"] ?? (proto == "trojan" ? "tls" : "none"), q: q, address: addr)
        return Server(id: "", name: comps.fragment ?? addr, proto: proto, host: addr, port: port, transport: net, outboundJSON: toJSON(ob))
    }

    // MARK: vmess

    static func parseVmess(_ link: String) throws -> Server {
        let body = String(link.dropFirst("vmess://".count))
        guard let decoded = base64Decode(body), let obj = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any] else {
            throw LinkError.malformed("vmess")
        }
        func s(_ k: String) -> String { if let v = obj[k] as? String { return v }; if let v = obj[k] { return "\(v)" }; return "" }
        let host = s("add"); guard let port = Int(s("port")), !host.isEmpty else { throw LinkError.malformed("vmess") }
        var q: [String: String] = ["path": s("path"), "host": s("host"), "sni": s("sni"), "alpn": s("alpn"),
                                   "fp": s("fp"), "headerType": s("type")]
        if s("net") == "grpc" { q["serviceName"] = s("path"); q["mode"] = s("type") == "multi" ? "multi" : "gun" }
        let net = normalizeNetwork(s("net").isEmpty ? "tcp" : s("net"))
        let security = s("tls") == "tls" ? "tls" : (s("tls") == "reality" ? "reality" : "none")
        let user: [String: Any] = ["id": s("id"), "alterId": Int(s("aid")) ?? 0, "security": s("scy").isEmpty ? "auto" : s("scy")]
        let ob: [String: Any] = [
            "protocol": "vmess",
            "settings": ["vnext": [["address": host, "port": port, "users": [user]]]],
            "streamSettings": streamSettings(network: net, security: security, q: q, address: host),
        ]
        return Server(id: "", name: s("ps").isEmpty ? host : s("ps"), proto: "vmess", host: host, port: port,
                      transport: net, outboundJSON: toJSON(ob))
    }

    // MARK: shadowsocks

    static func parseSS(_ link: String) throws -> Server {
        var body = String(link.dropFirst("ss://".count))
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding ?? ""
            body = String(body[..<hash])
        }
        if let qm = body.firstIndex(of: "?") {
            let q = String(body[body.index(after: qm)...])
            if q.contains("plugin=") { throw LinkError.unsupported(tr("Shadowsocks с плагином")) }
            body = String(body[..<qm])
        }
        var userinfo: String, hostport: String
        if let at = body.lastIndex(of: "@") {
            userinfo = String(body[..<at]); hostport = String(body[body.index(after: at)...])
            if let dec = base64Decode(userinfo.removingPercentEncoding ?? userinfo), dec.contains(":") { userinfo = dec }
            else { userinfo = userinfo.removingPercentEncoding ?? userinfo }
        } else {
            guard let dec = base64Decode(body), let at = dec.lastIndex(of: "@") else { throw LinkError.malformed("ss") }
            userinfo = String(dec[..<at]); hostport = String(dec[dec.index(after: at)...])
        }
        hostport = hostport.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let colon = userinfo.firstIndex(of: ":"), let pcolon = hostport.lastIndex(of: ":"),
              let port = Int(hostport[hostport.index(after: pcolon)...]) else { throw LinkError.malformed("ss") }
        let method = String(userinfo[..<colon]), password = String(userinfo[userinfo.index(after: colon)...])
        let host = String(hostport[..<pcolon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let ob: [String: Any] = ["protocol": "shadowsocks",
                                 "settings": ["servers": [["address": host, "port": port, "method": method, "password": password]]]]
        return Server(id: "", name: name.isEmpty ? host : name, proto: "shadowsocks", host: host, port: port,
                      transport: "tcp", outboundJSON: toJSON(ob))
    }

    // MARK: hysteria2

    static func parseHy2(_ link: String) throws -> Server {
        let normalized = link.replacingOccurrences(of: "hy2://", with: "hysteria2://", options: .anchored)
        guard let comps = URLComponents(string: normalized), let host = comps.host else { throw LinkError.malformed("hysteria2") }
        let port = comps.port ?? 443
        let q = query(comps)
        var auth = (comps.percentEncodedUser ?? "").removingPercentEncoding ?? ""
        if let pw = comps.percentEncodedPassword?.removingPercentEncoding { auth += ":" + pw }
        let addr = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let sni = q["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? addr
        let obfs = q["obfs"].flatMap { $0.isEmpty || $0 == "none" ? nil : $0 }
        let insecure = q["insecure"] == "1" || q["allowInsecure"] == "1"
        let name = comps.fragment ?? addr

        // obfs (salamander), insecure, порт-хоппинг — через sing-box.
        if obfs != nil || insecure || q["mport"] != nil {
            var ob: [String: Any] = ["type": "hysteria2", "server": addr, "server_port": port, "password": auth,
                                     "tls": ["enabled": true, "server_name": sni, "insecure": insecure, "alpn": ["h3"]]]
            if let obfs { ob["obfs"] = ["type": obfs, "password": q["obfs-password"] ?? ""] }
            if let up = q["upmbps"].flatMap(Int.init) { ob["up_mbps"] = up }
            if let down = q["downmbps"].flatMap(Int.init) { ob["down_mbps"] = down }
            if let mport = q["mport"], !mport.isEmpty { ob["server_ports"] = mport.split(separator: ",").map { part -> String in
                // sing-box принимает только диапазоны «a:b»; одиночный порт → «p:p».
                let r = part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":")
                return r.contains(":") ? r : "\(r):\(r)"
            } }
            return Server(id: "", name: name, proto: "hysteria2", host: addr, port: port, transport: "quic",
                          outboundJSON: toJSON(ob), engine: .singbox)
        }
        var tls: [String: Any] = ["serverName": sni, "alpn": ["h3"]]
        if let pin = q["pinSHA256"], !pin.isEmpty { tls["pinnedPeerCertSha256"] = pin }
        let ob: [String: Any] = [
            "protocol": "hysteria",
            "settings": ["version": 2, "address": addr, "port": port],
            "streamSettings": ["network": "hysteria", "security": "tls", "tlsSettings": tls,
                               "hysteriaSettings": ["version": 2, "auth": auth]],
        ]
        return Server(id: "", name: name, proto: "hysteria2", host: addr, port: port, transport: "quic", outboundJSON: toJSON(ob))
    }

    // MARK: TUIC (sing-box)

    static func parseTUIC(_ link: String) throws -> Server {
        guard let comps = URLComponents(string: link), let host = comps.host, let port = comps.port else { throw LinkError.malformed("tuic") }
        let q = query(comps)
        let uuid = (comps.percentEncodedUser ?? "").removingPercentEncoding ?? ""
        let pw = comps.percentEncodedPassword?.removingPercentEncoding ?? ""
        guard !uuid.isEmpty else { throw LinkError.malformed(tr("tuic: нет uuid")) }
        let addr = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let alpn = (q["alpn"].flatMap { $0.isEmpty ? nil : $0 } ?? "h3").split(separator: ",").map(String.init)
        let ob: [String: Any] = ["type": "tuic", "server": addr, "server_port": port, "uuid": uuid, "password": pw,
                                 "congestion_control": q["congestion_control"] ?? "bbr",
                                 "udp_relay_mode": q["udp_relay_mode"] ?? "native",
                                 "tls": ["enabled": true, "server_name": q["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? addr,
                                         "insecure": q["allow_insecure"] == "1" || q["insecure"] == "1", "alpn": alpn]]
        return Server(id: "", name: comps.fragment ?? addr, proto: "tuic", host: addr, port: port, transport: "quic",
                      outboundJSON: toJSON(ob), engine: .singbox)
    }

    // MARK: WireGuard (xray)

    static func parseWireGuard(_ link: String) throws -> Server {
        guard let comps = URLComponents(string: link), let host = comps.host, let port = comps.port else { throw LinkError.malformed("wireguard") }
        let q = query(comps)
        let secret = (comps.percentEncodedUser ?? "").removingPercentEncoding ?? q["privatekey"] ?? ""
        guard !secret.isEmpty, let pub = q["publickey"] ?? q["public_key"] else { throw LinkError.malformed(tr("wireguard: нет ключей")) }
        let addresses = (q["address"] ?? q["ip"] ?? "10.0.0.2/32").split(separator: ",").map { s -> String in
            let t = s.trimmingCharacters(in: .whitespaces); return t.contains("/") ? t : (t.contains(":") ? t + "/128" : t + "/32")
        }
        return try wireGuardServer(name: comps.fragment ?? host, host: host, port: port, secret: secret, publicKey: pub,
                                   psk: q["presharedkey"] ?? q["psk"], addresses: addresses, mtu: Int(q["mtu"] ?? ""),
                                   reserved: q["reserved"])
    }

    public static func parseWireGuardConf(_ text: String, name: String) throws -> Server {
        var section = "", iface: [String: String] = [:], peer: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if section == "[interface]" { iface[k] = v } else if section == "[peer]" { peer[k] = v }
        }
        if iface.keys.contains(where: { ["jc", "jmin", "jmax", "s1", "s2", "h1"].contains($0) }) {
            throw LinkError.unsupported(tr("AmneziaWG (его не умеет ни xray, ни sing-box)"))
        }
        guard let secret = iface["privatekey"], let pub = peer["publickey"], let ep = peer["endpoint"],
              let colon = ep.lastIndex(of: ":"), let port = Int(ep[ep.index(after: colon)...]) else {
            throw LinkError.malformed(tr("конфиг WireGuard"))
        }
        let host = String(ep[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let addrs = (iface["address"] ?? "10.0.0.2/32").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var s = try wireGuardServer(name: name, host: host, port: port, secret: secret, publicKey: pub, psk: peer["presharedkey"],
                                    addresses: addrs, mtu: Int(iface["mtu"] ?? ""), reserved: nil)
        s.id = stableID(text)
        return s
    }

    static func wireGuardServer(name: String, host: String, port: Int, secret: String, publicKey: String, psk: String?,
                                addresses: [String], mtu: Int?, reserved: String?) throws -> Server {
        var peer: [String: Any] = ["publicKey": publicKey, "endpoint": "\(host):\(port)", "allowedIPs": ["0.0.0.0/0", "::/0"]]
        if let psk, !psk.isEmpty { peer["preSharedKey"] = psk }
        var settings: [String: Any] = ["secretKey": secret, "address": addresses, "peers": [peer], "mtu": mtu ?? 1420]
        if let r = reserved?.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), r.count == 3 { settings["reserved"] = r }
        let ob: [String: Any] = ["protocol": "wireguard", "settings": settings]
        return Server(id: "", name: name, proto: "wireguard", host: host, port: port, transport: "udp", outboundJSON: toJSON(ob))
    }

    // MARK: SOCKS

    static func parseSocks(_ link: String) throws -> Server {
        var l = link
        // socks://base64(user:pass)@host:port
        if let at = l.range(of: "@"), let start = l.range(of: "://") {
            let cred = String(l[start.upperBound..<at.lowerBound])
            if !cred.contains(":"), let dec = base64Decode(cred.removingPercentEncoding ?? cred), dec.contains(":") {
                l.replaceSubrange(start.upperBound..<at.lowerBound, with: dec.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? dec)
            }
        }
        guard let comps = URLComponents(string: l), let host = comps.host, let port = comps.port else { throw LinkError.malformed("socks") }
        var server: [String: Any] = ["address": host, "port": port]
        if let u = comps.user, !u.isEmpty { server["users"] = [["user": u, "pass": comps.password ?? ""]] }
        let ob: [String: Any] = ["protocol": "socks", "settings": ["servers": [server]]]
        return Server(id: "", name: comps.fragment ?? host, proto: "socks", host: host, port: port, transport: "tcp", outboundJSON: toJSON(ob))
    }

    // MARK: transport / security

    static func normalizeNetwork(_ n: String) -> String {
        switch n.lowercased() {
        case "", "tcp", "raw": return "tcp"
        case "splithttp", "h2", "http": return "xhttp"
        default: return n.lowercased()
        }
    }

    static func streamSettings(network: String, security: String, q: [String: String], address: String) -> [String: Any] {
        func v(_ k: String) -> String? { if let x = q[k], !x.isEmpty { return x }; return nil }
        var ss: [String: Any] = ["network": network]
        switch network {
        case "ws":
            var w: [String: Any] = ["path": v("path") ?? "/"]
            if let h = v("host") { w["host"] = h }
            ss["wsSettings"] = w
        case "grpc":
            var g: [String: Any] = ["serviceName": v("serviceName") ?? v("path") ?? "", "multiMode": q["mode"] == "multi"]
            if let a = v("authority") { g["authority"] = a }
            ss["grpcSettings"] = g
        case "xhttp":
            var x: [String: Any] = ["path": v("path") ?? "/", "mode": v("mode") ?? "auto"]
            if let h = v("host") { x["host"] = h }
            if let e = v("extra"), let obj = try? JSONSerialization.jsonObject(with: Data(e.utf8)) { x["extra"] = obj }
            ss["xhttpSettings"] = x
        case "httpupgrade":
            var h: [String: Any] = ["path": v("path") ?? "/"]
            if let host = v("host") { h["host"] = host }
            ss["httpupgradeSettings"] = h
        case "kcp":
            var k: [String: Any] = ["header": ["type": v("headerType") ?? "none"]]
            if let seed = v("seed") { k["seed"] = seed }
            ss["kcpSettings"] = k
        default:
            if v("headerType") == "http" {
                var req: [String: Any] = ["path": [v("path") ?? "/"]]
                if let h = v("host") { req["headers"] = ["Host": h.split(separator: ",").map(String.init)] }
                ss["tcpSettings"] = ["header": ["type": "http", "request": req]]
            }
        }
        let alpn = v("alpn")?.split(separator: ",").map { String($0) }
        switch security {
        case "tls":
            var t: [String: Any] = ["serverName": v("sni") ?? v("host") ?? address]
            if let fp = v("fp") { t["fingerprint"] = fp }
            if let alpn { t["alpn"] = alpn }
            // allowInsecure в xray 26 удалён: доверие к сертификату — только через pcs/vcn из ссылки.
            if let pin = v("pcs") { t["pinnedPeerCertSha256"] = pin }
            if let vcn = v("vcn") { t["verifyPeerCertByName"] = vcn }
            if let ech = v("ech") { t["echConfigList"] = ech }
            ss["security"] = "tls"; ss["tlsSettings"] = t
        case "reality":
            var r: [String: Any] = ["serverName": v("sni") ?? "", "fingerprint": v("fp") ?? "chrome",
                                    "publicKey": v("pbk") ?? "", "shortId": v("sid") ?? ""]
            if let spx = v("spx") { r["spiderX"] = spx }
            if let pqv = v("pqv") { r["mldsa65Verify"] = pqv }
            ss["security"] = "reality"; ss["realitySettings"] = r
        default:
            ss["security"] = "none"
        }
        return ss
    }

    // MARK: допустимость

    /// Почему xray не примет этот сервер (nil — примет).
    /// xray 26 запрещает VLESS без TLS/Reality и без VLESS Encryption на публичный адрес.
    public static func rejectReason(_ s: Server) -> String? {
        guard s.engine == .xray else { return nil }
        let ob = s.outbound
        guard (ob["protocol"] as? String) == "vless" else { return nil }
        let sec = ((ob["streamSettings"] as? [String: Any])?["security"] as? String) ?? "none"
        guard sec == "none" else { return nil }
        let user = (((ob["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first?["users"] as? [[String: Any]])?.first
        let enc = (user?["encryption"] as? String) ?? "none"
        guard enc == "none" else { return nil }
        if isPrivateHost(s.host) { return nil }
        return tr("без шифрования — новая версия xray такие запрещает")
    }

    static func isPrivateHost(_ h: String) -> Bool {
        let host = h.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
                || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && (64...127).contains(p[1]))
        }
        return host.hasPrefix("fd") || host.hasPrefix("fe80") || host == "::1"
    }

    // MARK: helpers

    public static func base64Decode(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t), let str = String(data: d, encoding: .utf8) else { return nil }
        return str
    }

    public static func toJSON(_ obj: Any, pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    public static func stableID(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
