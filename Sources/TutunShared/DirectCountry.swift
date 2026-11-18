import Foundation

/// «Сайты страны — напрямую»: банки, госуслуги и местные сервисы выбранной страны идут без VPN.
/// Списки — из гео-баз runetfreedom (категории проверены в geosite.dat). Совпадает с Windows-версией.
public enum DirectCountry {
    public static let codes = ["ru", "cn", "ir", "mm", "tr", "ae"]
    public static let russiaDomains = ["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$",
                                       "domain:yandex.net", "domain:yastatic.net", "domain:vk.com", "domain:userapi.com",
                                       "domain:mycdn.me", "domain:ok.ru", "domain:max.ru", "domain:gosuslugi.ru"]

    /// Домены, идущие напрямую.
    public static func domains(_ code: String) -> [String] {
        switch code {
        case "cn": return ["geosite:cn", "regexp:\\.cn$"]
        case "ir": return ["geosite:category-ir", "regexp:\\.ir$"]
        case "mm": return ["geosite:category-bank-mm", "regexp:\\.mm$"]
        case "tr": return ["regexp:\\.tr$"]
        case "ae": return ["regexp:\\.ae$"]
        default: return russiaDomains
        }
    }
    /// IP-адреса страны. В гео-базе runetfreedom есть только RU, CN, IR — для Мьянмы, Турции и ОАЭ
    /// правило geoip:… xray отвергает, поэтому там только доменная зона.
    public static let withIPs: Set<String> = ["ru", "cn", "ir"]
    public static func ips(_ code: String) -> [String] { withIPs.contains(code) ? ["geoip:" + code] : [] }
    /// Домены, которые разрешает «DNS напрямую».
    public static func dnsDomains(_ code: String) -> [String] {
        code == "ru" || !codes.contains(code) ? ["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.xn--p1ai$"] : domains(code)
    }
    /// Доменные зоны страны — для DNS туннеля (sing-box не читает geosite): запросы к ним идут напрямую.
    public static func zones(_ code: String) -> [String] {
        switch code {
        case "cn": return ["cn"]
        case "ir": return ["ir"]
        case "mm": return ["mm"]
        case "tr": return ["tr"]
        case "ae": return ["ae"]
        default: return ["ru", "su", "xn--p1ai"]
        }
    }
    /// DNS для сайтов страны: 77.88.8.8 (Яндекс) по умолчанию годится только для России, для других — DNS провайдера.
    public static func dnsAddress(_ code: String, directDNS: String) -> String {
        code != "ru" && directDNS == "77.88.8.8" ? "localhost" : directDNS
    }
}
