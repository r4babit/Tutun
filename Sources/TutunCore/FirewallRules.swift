import Foundation
import TutunShared

/// Что маку разрешено слать наружу, пока VPN включён в режиме «весь трафик» с блокировкой.
/// Правила стоят всё время подключения (как у Mullvad и IVPN), а не включаются после обнаружения обрыва:
/// если туннель пропал или пакет пошёл мимо него (чужой маршрут от Wi-Fi, IPv6, сокет, привязанный к en0),
/// он упирается в запрет, а не уходит в открытую сеть.
public struct FirewallPolicy: Equatable, Sendable {
    public enum DNS: Equatable, Sendable {
        /// Туннеля нет (подключение, восстановление) или системный DNS не подменён: имена — в первую очередь
        /// адреса VPN-серверов — узнаёт системный резолвер macOS (mDNSResponder), ему выход разрешён.
        case systemResolver
        /// Туннель работает, системный DNS смотрит в него: порт 53 мимо туннеля закрыт для всех, кроме ядер Tutun.
        case tunnelOnly
    }
    public var dns: DNS
    /// «Исключённые адреса» из настроек: они идут мимо туннеля по маршруту, значит и здесь их надо пропустить.
    public var excludedRoutes: [String]

    public init(dns: DNS, excludedRoutes: [String] = []) {
        self.dns = dns; self.excludedRoutes = excludedRoutes
    }
}

public enum FirewallRules {
    /// В основном наборе правил macOS есть `anchor "com.apple/*"` — свой набор кладём туда и ничего системного не меняем.
    public static let anchor = "com.apple/tutun"
    /// Группа, с которой служба запускает xray и оба sing-box (tutun-drop). Только её процессам можно наружу напрямую.
    public static let group = "_tutun"
    public static let tunnelInterface = "utun233"
    static let resolverUser = "_mdnsresponder"

    /// Локальная сеть и служебные рассылки (список Mullvad, docs/security.md): роутер, принтер, AirPlay, AirDrop.
    static let lan4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
                       "224.0.0.0/24", "239.0.0.0/8", "255.255.255.255/32"]
    static let lan6 = ["fe80::/10", "fc00::/7", "ff01::/16", "ff02::/16", "ff03::/16", "ff04::/16", "ff05::/16"]

    /// Текст правил для `pfctl -a com.apple/tutun -f`. Порядок важен: срабатывает первое подошедшее (`quick`).
    public static func build(_ policy: FirewallPolicy) -> String {
        var lines = [
            "# Tutun: наружу — только через туннель и от ядер Tutun. Снять вручную: sudo pfctl -a \(anchor) -F rules",
            "pass quick on lo0 all flags any no state",
            "pass quick on \(tunnelInterface) all flags any no state",
            // Ядра: соединения с VPN-серверами, «напрямую» по правилам, DNS в обход VPN.
            "pass out quick proto { tcp, udp } all group \(group) flags any",
            // Получение адреса в сети.
            "pass out quick inet proto udp from any port 68 to any port 67",
            "pass out quick inet6 proto udp from any port 546 to any port 547",
            "pass out quick inet6 proto icmp6 all icmp6-type { routersol, neighbrsol, neighbradv }",
        ]
        switch policy.dns {
        case .systemResolver:
            // Разрешён только DNS mDNSResponder; остальные его TCP/UDP-соединения не должны обходить kill switch.
            lines.append("pass out quick proto { tcp, udp } from any to any port 53 user \(resolverUser) flags any no state")
        case .tunnelOnly:
            // До правила локальной сети: иначе запросы имён утекали бы на роутер.
            lines.append("block return out quick proto { tcp, udp } from any to any port 53")
        }
        lines.append("pass out quick inet from any to { \(lan4.joined(separator: ", ")) } flags any no state")
        lines.append("pass out quick inet6 from any to { \(lan6.joined(separator: ", ")) } flags any no state")
        for route in exclusions(policy.excludedRoutes) {
            lines.append("pass out quick \(route.contains(":") ? "inet6" : "inet") from any to \(route) flags any no state")
        }
        lines.append("block return out quick all")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Только проверенные адреса и подсети: строки из настроек попадают в правила root-службы.
    public static func exclusions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return ConfigBuilder.cleaned(raw).compactMap(ConfigBuilder.cidr).filter { seen.insert($0).inserted }
    }
}
