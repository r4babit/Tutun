import Foundation

/// Язык интерфейса. Русский — исходный: ключи перевода — сами русские строки,
/// переводы лежат в `L10nStrings.swift` (порядок столбцов — `AppLanguage.translated`).
/// 19 самых распространённых языков мира (по Ethnologue, без диалектов уже включённых языков) + украинский.
/// Раскладка окна одинаковая для всех языков: арабский и урду не зеркалятся.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, zh, hi, es, ar, fr, bn, pt, ru, ur, id, de, ja, mr, te, tr, ta, vi, ko, uk

    /// Порядок переводов в таблице L10nStrings.
    static let translated: [AppLanguage] = [.en, .uk, .es, .zh, .hi, .ar, .fr, .bn, .pt, .ur,
                                            .id, .de, .ja, .mr, .te, .tr, .ta, .vi, .ko]

    /// Название языка — всегда на нём самом, чтобы найти свой в любом интерфейсе.
    public var nativeName: String {
        switch self {
        case .system: return TutunShared.tr("Как в системе")   // .tr — турецкий, поэтому явно
        case .ru: return "Русский"
        case .en: return "English"
        case .uk: return "Українська"
        case .zh: return "中文（简体）"
        case .hi: return "हिन्दी"
        case .es: return "Español"
        case .ar: return "العربية"
        case .fr: return "Français"
        case .bn: return "বাংলা"
        case .pt: return "Português"
        case .ur: return "اردو"
        case .id: return "Bahasa Indonesia"
        case .de: return "Deutsch"
        case .ja: return "日本語"
        case .mr: return "मराठी"
        case .te: return "తెలుగు"
        case .tr: return "Türkçe"
        case .ta: return "தமிழ்"
        case .vi: return "Tiếng Việt"
        case .ko: return "한국어"
        }
    }
}

public enum L10n {
    static let defaultsKey = "tutun.language"

    /// Выбор пользователя (может быть «как в системе»).
    public static var choice: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Язык, на котором сейчас показывается интерфейс (без «как в системе»).
    nonisolated(unsafe) public private(set) static var current: AppLanguage = resolve(choice)

    public static func set(_ lang: AppLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: defaultsKey)
        // Системные окна (открыть файл и т. п.) подхватят язык при следующем запуске.
        if lang == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages") }
        current = resolve(lang)
    }

    static func resolve(_ lang: AppLanguage) -> AppLanguage {
        guard lang == .system else { return lang }
        // Свои AppleLanguages приложения не учитываем — смотрим на язык системы.
        let system = (UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: "AppleLanguages")
                      ?? Locale.preferredLanguages)
        for code in system {
            let base = String(code.prefix { $0 != "-" && $0 != "_" })
            if let l = AppLanguage(rawValue: base), l != .system { return l }
        }
        return .en   // язык системы не из списка — английский
    }

    /// Локаль для названий стран и дат.
    public static var locale: Locale {
        switch current {
        case .en: return Locale(identifier: "en_US")
        case .uk: return Locale(identifier: "uk_UA")
        case .zh: return Locale(identifier: "zh_CN")
        case .hi: return Locale(identifier: "hi_IN")
        case .es: return Locale(identifier: "es_ES")
        case .ar: return Locale(identifier: "ar")
        case .fr: return Locale(identifier: "fr_FR")
        case .bn: return Locale(identifier: "bn_BD")
        case .pt: return Locale(identifier: "pt_BR")
        case .ur: return Locale(identifier: "ur_PK")
        case .id: return Locale(identifier: "id_ID")
        case .de: return Locale(identifier: "de_DE")
        case .ja: return Locale(identifier: "ja_JP")
        case .mr: return Locale(identifier: "mr_IN")
        case .te: return Locale(identifier: "te_IN")
        case .tr: return Locale(identifier: "tr_TR")
        case .ta: return Locale(identifier: "ta_IN")
        case .vi: return Locale(identifier: "vi_VN")
        case .ko: return Locale(identifier: "ko_KR")
        default: return Locale(identifier: "ru_RU")
        }
    }

    /// «3 сервера» / «3 servers» / «3 сервери».
    public static func servers(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let one = m10 == 1 && m100 != 11
        let few = (2...4).contains(m10) && !(12...14).contains(m100)
        switch current {
        case .en: return "\(n) \(n == 1 ? "server" : "servers")"
        case .uk: return "\(n) \(one ? "сервер" : few ? "сервери" : "серверів")"
        case .es: return "\(n) \(n == 1 ? "servidor" : "servidores")"
        case .pt: return "\(n) \(n == 1 ? "servidor" : "servidores")"
        case .fr: return "\(n) \(n <= 1 ? "serveur" : "serveurs")"
        case .zh: return "\(n) 个服务器"
        case .hi: return "\(n) सर्वर"
        case .bn: return "\(n)টি সার্ভার"
        case .ur: return "\(n) \(n == 1 ? "سرور" : "سرورز")"
        case .id: return "\(n) server"
        case .de: return "\(n) Server"
        case .ja: return "\(n) 台のサーバー"
        case .mr: return "\(n) सर्व्हर"
        case .te: return "\(n) \(n == 1 ? "సర్వర్" : "సర్వర్లు")"
        case .tr: return "\(n) sunucu"
        case .ta: return "\(n) \(n == 1 ? "சர்வர்" : "சர்வர்கள்")"
        case .vi: return "\(n) máy chủ"
        case .ko: return "서버 \(n)개"
        case .ar:
            switch n {
            case 1: return "خادم واحد"
            case 2: return "خادمان"
            case 3...10: return "\(n) خوادم"
            default: return "\(n) خادم"
            }
        default: return "\(n) \(one ? "сервер" : few ? "сервера" : "серверов")"
        }
    }

    static func lookup(_ key: String) -> String {
        guard let i = AppLanguage.translated.firstIndex(of: current) else { return key }
        return L10nStrings.table[key]?[i] ?? key
    }

    /// Подставляет аргументы: «%@» — по порядку, «%1$@», «%2$@» — по номеру.
    static func fill(_ s: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return s }
        var out = "", next = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%" {
                let rest = s[s.index(after: i)...]
                if rest.hasPrefix("@") {
                    out += next < args.count ? args[next] : ""; next += 1
                    i = s.index(i, offsetBy: 2); continue
                }
                if let d = rest.first, let n = d.wholeNumberValue, rest.dropFirst().hasPrefix("$@") {
                    out += n - 1 < args.count ? args[n - 1] : ""
                    i = s.index(i, offsetBy: 4); continue
                }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}

/// Строка для перевода: литерал с интерполяцией превращается в ключ «… %@ …» и список аргументов.
public struct Loc: ExpressibleByStringInterpolation {
    public let key: String
    public let args: [String]

    public init(stringLiteral value: String) { key = value; args = [] }

    public init(stringInterpolation i: StringInterpolation) { key = i.key; args = i.args }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = "", args: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) { key += s }
        public mutating func appendInterpolation<T>(_ v: T) { key += "%@"; args.append("\(v)") }
    }
}

/// Перевод строки интерфейса: `tr("Подключено")`, `tr("Сервер «\(name)»")`.
public func tr(_ s: Loc) -> String { L10n.fill(L10n.lookup(s.key), s.args) }

/// Перевод готовой строки, пришедшей из службы или из другого места целиком.
public func trDynamic(_ s: String) -> String {
    let t = L10n.lookup(s)
    if t != s || L10n.current == .ru { return t }
    // «Префикс: подробности ядра» — переводим только префикс.
    if let r = s.range(of: ": ") {
        let head = String(s[..<r.lowerBound]) + ": "
        let h = L10n.lookup(head)
        if h != head { return h + s[r.upperBound...] }
    }
    return s
}
