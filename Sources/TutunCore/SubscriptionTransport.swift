import Foundation

public enum SubscriptionTransport {
    static let deviceHeaders = ["X-HWID", "X-Device-OS", "X-Ver-OS", "X-Device-Model", "X-Device-Locale"]
    public static func secure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty }
    /// https — всегда; http — только если пользователь включил «Разрешить подписки по http».
    public static func allowed(_ url: URL, allowHTTP: Bool) -> Bool {
        secure(url) || (allowHTTP && url.scheme?.lowercased() == "http" && !(url.host ?? "").isEmpty)
    }
    public static func redirect(_ request: URLRequest, from previous: URL, allowHTTP: Bool = false) -> URLRequest? {
        guard let next = request.url, allowed(next, allowHTTP: allowHTTP) else { return nil }
        var forwarded = request
        // По http данные устройства не уходят никогда, даже на тот же адрес.
        if !secure(next) { for header in deviceHeaders { forwarded.setValue(nil, forHTTPHeaderField: header) } }
        if previous.host?.lowercased() != next.host?.lowercased() || previous.scheme?.lowercased() != next.scheme?.lowercased()
            || (previous.port ?? 443) != (next.port ?? 443) {
            for header in ["X-HWID", "X-Device-OS", "X-Ver-OS", "X-Device-Model", "X-Device-Locale", "Authorization", "Cookie"] { forwarded.setValue(nil, forHTTPHeaderField: header) }
        }
        return forwarded
    }
}
final class SubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowHTTP: Bool
    init(allowHTTP: Bool) { self.allowHTTP = allowHTTP }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let previous = response.url else { completionHandler(nil); return }
        completionHandler(SubscriptionTransport.redirect(request, from: previous, allowHTTP: allowHTTP))
    }
}
