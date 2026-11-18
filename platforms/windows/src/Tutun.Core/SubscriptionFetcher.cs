using System.Net;

namespace Tutun.Core;

public sealed class SubscriptionException(string message) : Exception(message);

public sealed record SubscriptionResult(List<Server> Servers, List<RoutingProfile> Profiles, List<string> Skipped, Subscription Meta);

public sealed record FetchOptions(string Hwid, bool SendHWID, string UserAgent, TimeSpan Timeout, bool AllowHttp = false);

public static class SubscriptionFetcher
{
    public const string DefaultUserAgent = "Tutun/2.0 (Windows)";

    /// Скачивает подписку. Заголовки устройства нужны панелям с лимитом устройств (Remnawave и т.п.).
    public static async Task<SubscriptionResult> FetchAsync(Subscription sub, FetchOptions o, CancellationToken ct = default)
    {
        // По умолчанию только HTTPS: в ссылке и ответе — ключи серверов. http — только если пользователь разрешил в настройках.
        if (!Uri.TryCreate(sub.Url.Trim(), UriKind.Absolute, out var url) || (url.Scheme != Uri.UriSchemeHttps && url.Scheme != Uri.UriSchemeHttp))
            throw new SubscriptionException("Неверная ссылка подписки");
        if (url.Scheme == Uri.UriSchemeHttp && !o.AllowHttp)
            throw new SubscriptionException("Подписка по http:// не защищена: ключи серверов видны в сети. Ссылка должна начинаться с https:// — или включите «Разрешить подписки по http» в настройках.");
        // Переадресацию обрабатываем сами: на чужой адрес данные устройства не уходят.
        using var handler = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All, AllowAutoRedirect = false, UseCookies = false };
        using var http = new HttpClient(handler) { Timeout = o.Timeout };
        var sendDevice = o.SendHWID && url.Scheme == Uri.UriSchemeHttps;
        HttpResponseMessage? resp = null;
        try
        {
            for (int hop = 0; ; hop++)
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.TryAddWithoutValidation("User-Agent", string.IsNullOrWhiteSpace(o.UserAgent) ? DefaultUserAgent : o.UserAgent);
                // По открытому http ID устройства не отправляется никогда.
                if (sendDevice)
                {
                    var v = Environment.OSVersion.Version;
                    req.Headers.TryAddWithoutValidation("X-HWID", o.Hwid);
                    req.Headers.TryAddWithoutValidation("X-Device-OS", "Windows");
                    req.Headers.TryAddWithoutValidation("X-Ver-OS", $"{v.Major}.{v.Minor}.{v.Build}");
                    req.Headers.TryAddWithoutValidation("X-Device-Model", "Windows");   // без имени компьютера
                    req.Headers.TryAddWithoutValidation("X-Device-Locale", "ru_RU");
                }
                resp = await http.SendAsync(req, ct);
                var code = (int)resp.StatusCode;
                if (code is not (301 or 302 or 303 or 307 or 308) || resp.Headers.Location is not { } loc) break;
                if (hop >= 5) throw new SubscriptionException("Слишком много переадресаций");
                var next = loc.IsAbsoluteUri ? loc : new Uri(url, loc);
                if (next.Scheme == Uri.UriSchemeHttp && !o.AllowHttp) throw new SubscriptionException("Подписка переадресует на небезопасный http:// — это можно разрешить в настройках.");
                if (next.Scheme != Uri.UriSchemeHttps && next.Scheme != Uri.UriSchemeHttp) throw new SubscriptionException("Неверная переадресация подписки");
                resp.Dispose(); resp = null;
                sendDevice &= next.Scheme == Uri.UriSchemeHttps && Uri.Compare(next, url, UriComponents.SchemeAndServer,
                    UriFormat.UriEscaped, StringComparison.OrdinalIgnoreCase) == 0;
                url = next;
            }
        }
        catch (TaskCanceledException) { throw new SubscriptionException("Сервер подписки не ответил вовремя"); }
        catch (HttpRequestException e) { throw new SubscriptionException("Не удалось скачать подписку: " + e.Message); }
        using var _ = resp;
        if (resp == null) throw new SubscriptionException("Пустой ответ сервера подписки");
        if (!resp.IsSuccessStatusCode) throw new SubscriptionException($"Сервер подписки ответил ошибкой {(int)resp.StatusCode}");
        string? H(string name) =>
            resp.Headers.TryGetValues(name, out var v) ? v.FirstOrDefault()
            : resp.Content.Headers.TryGetValues(name, out var c) ? c.FirstOrDefault() : null;

        if (H("x-hwid-max-devices-reached") == "true")
            throw new SubscriptionException("Провайдер: превышен лимит устройств. Удалите старое устройство в кабинете/боте провайдера и обновите подписку.");
        if (H("x-hwid-not-supported") == "true")
            throw new SubscriptionException("Провайдер не выдал серверы этому устройству (включите «Отправлять ID устройства»).");

        var meta = sub.Copy();
        if (H("subscription-userinfo") is { } info)
        {
            foreach (var part in info.Split(';'))
            {
                var kv = part.Split('=', 2).Select(x => x.Trim()).ToArray();
                if (kv.Length != 2 || !long.TryParse(kv[1], out var n)) continue;
                switch (kv[0])
                {
                    case "upload": meta.Upload = n; break;
                    case "download": meta.Download = n; break;
                    case "total": meta.Total = n; break;
                    case "expire": meta.Expire = n > 0 ? DateTimeOffset.FromUnixTimeSeconds(n) : null; break;
                }
            }
        }
        if (H("profile-title") is { } title && DecodeMaybeBase64(title) is { Length: > 0 } t && (sub.Name.Length == 0 || sub.Name == "Подписка"))
            meta.Name = t;
        meta.Announce = H("announce") is { } a ? DecodeMaybeBase64(a) : null;
        meta.SupportURL = H("support-url");
        meta.WebPageURL = H("profile-web-page-url");
        if (int.TryParse(H("profile-update-interval"), out var hours) && hours > 0) meta.UpdateIntervalHours = Math.Min(hours, 168);

        var body = await resp.Content.ReadAsStringAsync(ct);
        var parsed = LinkParser.ParseBatch(body, sub.Id);
        // Профиль маршрутов может прийти заголовком «routing» (формат Happ).
        if (H("routing") is { } r && (RoutingProfiles.ParseLink(r) ?? RoutingProfiles.ParseJSON(LinkParser.Base64Decode(r) ?? r)) is { } prof)
        {
            prof.FromSubscription = sub.Id;
            parsed.Profiles.Add(prof);
        }
        if (parsed.Servers.Count == 0)
            throw new SubscriptionException("В подписке нет поддерживаемых серверов" + (parsed.Errors.Count == 0 ? "" : ": " + string.Join("; ", parsed.Errors.Take(3))));
        meta.LastUpdate = DateTimeOffset.Now; meta.LastError = null;
        return new SubscriptionResult(parsed.Servers, parsed.Profiles, parsed.Errors, meta);
    }

    static string DecodeMaybeBase64(string s) =>
        s.StartsWith("base64:") ? LinkParser.Base64Decode(s[7..]) ?? s : s;
}
