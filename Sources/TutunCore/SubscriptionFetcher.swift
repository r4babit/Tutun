import Foundation
import TutunShared

public enum SubscriptionError: Error, LocalizedError {
    case badURL
    case insecureHTTP
    case http(Int)
    case deviceLimit
    case deviceNotSupported
    case empty([String])

    public var errorDescription: String? {
        switch self {
        case .badURL: return tr("Неверная ссылка подписки")
        case .insecureHTTP: return tr("Подписка по http:// не защищена. Если это ваша панель без https, включите «Разрешить подписки по http» в настройках подписок.")
        case .http(let c): return tr("Сервер подписки ответил ошибкой \(c)")
        case .deviceLimit: return tr("Провайдер: превышен лимит устройств. Удалите старое устройство в кабинете/боте провайдера и обновите подписку.")
        case .deviceNotSupported: return tr("Провайдер не выдал серверы этому устройству (включите «Отправлять ID устройства»).")
        case .empty(let errs): return tr("В подписке нет поддерживаемых серверов") + (errs.isEmpty ? "" : ": " + errs.prefix(3).joined(separator: "; "))
        }
    }
}

public struct SubscriptionResult: Sendable {
    public var servers: [Server]
    public var profiles: [RoutingProfile]
    public var skipped: [String]
    public var meta: Subscription
    /// Провайдер перенёс подписку (`new-url`/`new-domain`): новый адрес, https.
    public var newURL: String?
}

public struct FetchOptions: Sendable {
    public var hwid: String
    public var sendHWID: Bool
    public var userAgent: String
    public var timeout: TimeInterval
    public var allowHTTP: Bool
    public init(hwid: String, sendHWID: Bool, userAgent: String, timeout: TimeInterval, allowHTTP: Bool = false) {
        self.hwid = hwid; self.sendHWID = sendHWID; self.userAgent = userAgent; self.timeout = timeout; self.allowHTTP = allowHTTP
    }
}

public enum SubscriptionFetcher {
    public static var defaultUserAgent: String { "Tutun/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (macOS)" }

    /// Скачивает подписку. Заголовки устройства нужны панелям с лимитом устройств (Remnawave и т.п.).
    public static func fetch(_ sub: Subscription, options o: FetchOptions) async throws -> SubscriptionResult {
        guard let url = URL(string: sub.url.trimmingCharacters(in: .whitespacesAndNewlines)), !(url.host ?? "").isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SubscriptionError.badURL
        }
        guard SubscriptionTransport.allowed(url, allowHTTP: o.allowHTTP) else { throw SubscriptionError.insecureHTTP }
        var req = URLRequest(url: url, timeoutInterval: o.timeout)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        req.setValue(o.userAgent.isEmpty ? defaultUserAgent : o.userAgent, forHTTPHeaderField: "User-Agent")
        if o.sendHWID, SubscriptionTransport.secure(url) {
            req.setValue(o.hwid, forHTTPHeaderField: "X-HWID")
            req.setValue("macOS", forHTTPHeaderField: "X-Device-OS")
            req.setValue("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", forHTTPHeaderField: "X-Ver-OS")
            req.setValue("Mac", forHTTPHeaderField: "X-Device-Model")
            req.setValue(L10n.locale.identifier, forHTTPHeaderField: "X-Device-Locale")
        }

        let session = URLSession(configuration: .ephemeral, delegate: SubscriptionRedirectDelegate(allowHTTP: o.allowHTTP), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, resp) = try await session.bytes(for: req)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1024 * 1024 else { throw SubscriptionError.badURL }
            data.append(byte)
        }
        guard let http = resp as? HTTPURLResponse else { throw SubscriptionError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionError.http(http.statusCode) }
        func header(_ name: String) -> String? {
            http.value(forHTTPHeaderField: name).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        if header("x-hwid-max-devices-reached") == "true" { throw SubscriptionError.deviceLimit }
        if header("x-hwid-not-supported") == "true" { throw SubscriptionError.deviceNotSupported }

        var parsed = LinkParser.parseBatch(data, subscriptionID: sub.id)
        // Заголовок важнее такой же строки «#ключ: значение» в теле подписки.
        func value(_ name: String) -> String? { header(name) ?? parsed.meta[name] }

        var meta = sub
        if let info = header("subscription-userinfo") {
            for part in info.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let n = Int64(kv[1]) else { continue }
                switch kv[0] {
                case "upload": meta.upload = n
                case "download": meta.download = n
                case "total": meta.total = n
                case "expire": meta.expire = n > 0 ? Date(timeIntervalSince1970: TimeInterval(n)) : nil
                default: break
                }
            }
        }
        let title = (value("profile-title") ?? value("subscription-name")).map(decodeMaybeBase64)
            ?? ProviderOptions.filename(header("content-disposition"))
        if let t = title, !t.isEmpty, sub.name.isEmpty || sub.name == "Подписка" { meta.name = String(t.prefix(40)) }
        meta.announce = value("announce").map(decodeMaybeBase64)
        meta.supportURL = value("support-url")
        meta.webPageURL = value("profile-web-page-url")
        meta.details = value("profile-description").map(decodeMaybeBase64)
        meta.supportEmail = value("support-email").flatMap { $0.contains("@") && !$0.contains(" ") ? $0 : nil }
        meta.announceURL = ProviderOptions.httpsURL(value("announce-url"))
        if let h = value("profile-update-interval").flatMap(Int.init), h > 0 { meta.updateIntervalHours = h }
        meta.serverResolve = ProviderOptions.serverResolve(header)
        meta.providerFragment = ProviderOptions.fragment(header)
        meta.providerNoises = ProviderOptions.noises(header)

        // Маршруты. Приоритет как у INCY: заголовок autorouting → ссылка в теле → заголовок routing → профиль в теле.
        let autoHeader = header("autorouting").flatMap { v -> String? in
            if let r = v.range(of: "https://", options: .caseInsensitive) { return ProviderOptions.httpsURL(String(v[r.lowerBound...])) }
            return nil
        }
        meta.autoroutingURL = autoHeader ?? parsed.routingURLs.first
        if let url = meta.autoroutingURL, var p = await fetchRoutingProfile(url, timeout: o.timeout) {
            p.fromSubscription = sub.id
            parsed.profiles = [p]
        } else if let r = header("routing"), var p = RoutingProfiles.parseLink(r) ?? RoutingProfiles.parseJSON(Data((LinkParser.base64Decode(r) ?? r).utf8)) {
            p.fromSubscription = sub.id
            parsed.profiles.insert(p, at: 0)
        }
        guard !parsed.servers.isEmpty else { throw SubscriptionError.empty(parsed.errors) }
        meta.lastUpdate = Date(); meta.lastError = nil
        let newURL = ProviderOptions.migration(from: url, header)
        return SubscriptionResult(servers: parsed.servers, profiles: parsed.profiles, skipped: parsed.errors, meta: meta, newURL: newURL)
    }

    /// Профиль маршрутов по ссылке провайдера: только https, не больше 1 МБ, без данных устройства.
    static func fetchRoutingProfile(_ url: String, timeout: TimeInterval) async -> RoutingProfile? {
        guard let u = URL(string: url) else { return nil }
        let session = URLSession(configuration: .ephemeral, delegate: SubscriptionRedirectDelegate(allowHTTP: false), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, resp) = try? await session.data(for: URLRequest(url: u, timeoutInterval: timeout)),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true, data.count <= 1 << 20 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return RoutingProfiles.parseJSON(Data(text.utf8)) ?? RoutingProfiles.parseLink(text)
            ?? LinkParser.base64Decode(text).flatMap { RoutingProfiles.parseJSON(Data($0.utf8)) }
    }

    static func decodeMaybeBase64(_ s: String) -> String {
        if s.hasPrefix("base64:") { return LinkParser.base64Decode(String(s.dropFirst(7))) ?? s }
        return s
    }
}
