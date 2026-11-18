import Foundation
import TutunShared

/// Профили маршрутов в формате Happ: happ://routing/add/<base64 JSON> (а также onadd) или сам JSON.
/// Ключи: Name, DirectSites, DirectIp, ProxySites, ProxyIp, BlockSites, BlockIp, DomainStrategy,
/// RemoteDns / RemoteDNSIP / RemoteDNSType + RemoteDNSDomain, DomesticDns / DomesticDNSIP,
/// DnsHosts, RouteOrder, Geoipurl, Geositeurl, GlobalProxy.
public enum RoutingProfiles {
    public static func parseLink(_ link: String) -> RoutingProfile? {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = l.lowercased()
        for prefix in ["happ://routing/add/", "happ://routing/onadd/", "tutun://routing/add/", "tutun://routing/"] where lower.hasPrefix(prefix) {
            let payload = String(l.dropFirst(prefix.count))
            let text = LinkParser.base64Decode(payload) ?? payload.removingPercentEncoding ?? payload
            return parseJSON(Data(text.utf8))
        }
        return nil
    }

    public static func parseJSON(_ data: Data) -> RoutingProfile? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func list(_ k: String) -> [String] {
            if let a = o[k] as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if let s = o[k] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            return []
        }
        // Регистр ключей у генераторов разный (Happ пишет RemoteDNSIP, старые профили — RemoteDnsIP): ищем без учёта регистра.
        let lowered = Dictionary(o.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        func str(_ k: String) -> String? {
            ((o[k] ?? lowered[k.lowercased()]) as? String).flatMap { v in
                let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
            }
        }
        var p = RoutingProfile(name: str("Name") ?? str("name") ?? tr("Профиль"))
        p.directSites = list("DirectSites"); p.directIPs = list("DirectIp")
        p.proxySites = list("ProxySites"); p.proxyIPs = list("ProxyIp")
        p.blockSites = list("BlockSites"); p.blockIPs = list("BlockIp")
        p.domainStrategy = str("DomainStrategy")
        // DoH-адрес (RemoteDNSType = DoH) важнее простого IP: его и xray, и туннель понимают как https://….
        let doh = str("RemoteDNSType")?.lowercased() == "doh" ? str("RemoteDNSDomain").flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil } : nil
        p.remoteDNS = doh ?? str("RemoteDNSIP") ?? str("RemoteDns")
        // «DNS напрямую» остаётся IP: к нему туннель ходит в обход VPN, имя пришлось бы где-то спрашивать.
        p.directDNS = str("DomesticDNSIP") ?? str("DomesticDns")
        if let hosts = (o["DnsHosts"] ?? lowered["dnshosts"]) as? [String: Any] {
            var clean: [String: String] = [:]
            for (domain, value) in hosts {
                let d = domain.lowercased().trimmingCharacters(in: .whitespaces)
                var a4 = in_addr(), a6 = in6_addr()
                guard let ip = (value as? String)?.trimmingCharacters(in: .whitespaces), !d.isEmpty, !d.contains(" "),
                      inet_pton(AF_INET, ip, &a4) == 1 || inet_pton(AF_INET6, ip, &a6) == 1 else { continue }
                clean[d] = ip
            }
            if !clean.isEmpty { p.dnsHosts = clean }
        }
        if let order = str("RouteOrder")?.lowercased(), Self.routeGroups(order) != nil { p.routeOrder = order }
        p.geoipURL = str("Geoipurl"); p.geositeURL = str("Geositeurl")
        if let g = o["GlobalProxy"] { p.globalProxy = "\(g)".lowercased() != "false" }
        let hasRules = !(p.directSites + p.directIPs + p.proxySites + p.proxyIPs + p.blockSites + p.blockIPs).isEmpty
        return hasRules || p.geoipURL != nil ? p : nil
    }

    /// «block-proxy-direct» → порядок групп; nil, если это не перестановка трёх групп.
    public static func routeGroups(_ order: String?) -> [String]? {
        guard let parts = order?.lowercased().split(separator: "-").map(String.init),
              parts.count == 3, Set(parts) == ["block", "proxy", "direct"] else { return nil }
        return parts
    }

    /// Ссылка для отправки профиля на другое устройство (Happ её тоже понимает).
    public static func link(for p: RoutingProfile) -> String {
        var o: [String: Any] = ["Name": p.name, "DirectSites": p.directSites, "DirectIp": p.directIPs,
                                "ProxySites": p.proxySites, "ProxyIp": p.proxyIPs, "BlockSites": p.blockSites,
                                "BlockIp": p.blockIPs, "GlobalProxy": p.globalProxy ? "true" : "false"]
        if let d = p.domainStrategy { o["DomainStrategy"] = d }
        if let d = p.remoteDNS { o["RemoteDns"] = d }
        if let d = p.directDNS { o["DomesticDns"] = d }
        if let h = p.dnsHosts, !h.isEmpty { o["DnsHosts"] = h }
        if let r = p.routeOrder { o["RouteOrder"] = r }
        if let u = p.geoipURL { o["Geoipurl"] = u }
        if let u = p.geositeURL { o["Geositeurl"] = u }
        return "happ://routing/add/" + Data(LinkParser.toJSON(o).utf8).base64EncodedString()
    }
}
