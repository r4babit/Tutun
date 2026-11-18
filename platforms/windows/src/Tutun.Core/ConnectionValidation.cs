using System.Text.Json.Nodes;

namespace Tutun.Core;

public sealed class ValidationException(string message) : Exception(message);

/// Проверка описания подключения перед тем, как служба (SYSTEM) соберёт и запустит конфиг.
public static class ConnectionValidation
{
    public static bool HttpURL(string text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https") && u.Host.Length > 0;

    static readonly HashSet<string> XrayProtocols = ["vless", "vmess", "trojan", "shadowsocks", "hysteria", "wireguard", "socks"];
    static readonly HashSet<string> SingBoxProtocols = ["hysteria2", "tuic"];

    public static void Validate(ConnectionInput input)
    {
        if (input.Servers.Count is < 1 or > 25) throw new ValidationException("Нужно от 1 до 25 серверов");
        var s = input.Settings;
        var p = input.Profile;
        var ruleLists = s.DirectDomains.Concat(s.ProxyDomains).Concat(s.BlockDomains).Concat(s.DirectIPs).Concat(s.ProxyIPs).Concat(s.BlockIPs)
            .Concat(p?.DirectSites ?? []).Concat(p?.ProxySites ?? []).Concat(p?.BlockSites ?? [])
            .Concat(p?.DirectIPs ?? []).Concat(p?.ProxyIPs ?? []).Concat(p?.BlockIPs ?? []);
        if (ruleLists.Any(r => r.Trim().StartsWith("ext:", StringComparison.OrdinalIgnoreCase)))
            throw new ValidationException("Внешние файлы правил недопустимы в конфиге службы");
        if (s.ProbeIntervalSec is < 10 or > 300 || s.HealthFailLimit is < 1 or > 10 || s.TestTimeout is < 2 or > 30
            || s.MuxConcurrency is < 1 or > 128 || !HttpURL(s.TestURL) || s.LogLevel is not ("debug" or "info" or "warning" or "error" or "none"))
            throw new ValidationException("Недопустимые параметры подключения");
        if (s.AllowLAN)
        {
            if (string.IsNullOrWhiteSpace(s.LanUser) || string.IsNullOrWhiteSpace(s.LanPassword))
                throw new ValidationException("Для раздачи VPN нужны логин и пароль");
            var reserved = new HashSet<int> { Paths.SocksPort, Paths.HttpPort, Paths.ApiPort, Paths.ClashPort };
            for (int i = 0; i < 25; i++) { reserved.Add(Paths.HelperBasePort + i); reserved.Add(Paths.ProbeBasePort + i); }
            if (s.LanSocksPort is < 1025 or > 65000 || s.LanHttpPort is < 1025 or > 65000 || s.LanSocksPort == s.LanHttpPort
                || reserved.Contains(s.LanSocksPort) || reserved.Contains(s.LanHttpPort))
                throw new ValidationException("Порты локальной сети совпадают или заняты Tutun");
        }
        if (HomeRegions.All.All(r => r.Code != s.DirectCountry)) throw new ValidationException("Неизвестная страна для правил «напрямую»");
        // Имена процессов в правилах приложений: только имя файла, без путей к чужим каталогам и шаблонов.
        foreach (var app in s.DirectApps.Concat(s.IncludeApps).Concat(input.ExtraDirectProcesses))
            if (app.IndexOfAny(['"', '<', '>', '|', '*', '?']) >= 0) throw new ValidationException("Недопустимое имя приложения в правилах");

        var all = input.Chain == null ? input.Servers : input.Servers.Append(input.Chain);
        foreach (var server in all)
        {
            var outbound = Json.ParseObject(server.OutboundJSON) ?? throw new ValidationException("Повреждён конфиг сервера");
            var proto = outbound.Str("protocol") ?? outbound.Str("type") ?? "";
            var allowed = server.Engine == Engine.Xray ? XrayProtocols : SingBoxProtocols;
            if (!allowed.Contains(proto) || ContainsFileReference(outbound))
                throw new ValidationException("Недопустимый протокол или доступ к файлам в конфиге сервера");
        }
    }

    /// Клиентский конфиг не должен заставлять ядро с правами SYSTEM читать файлы или каналы.
    static bool ContainsFileReference(JsonNode? value)
    {
        switch (value)
        {
            case JsonObject dict:
                foreach (var (key, item) in dict)
                {
                    var k = key.ToLowerInvariant();
                    if (k.EndsWith("file") || k.EndsWith("filepath") || k.EndsWith("_path")
                        || k is "directory" or "masterkeylog" or "keylog" or "keylogpath" or "dssettings" or "acme") return true;
                    if (k is "address" or "server" or "endpoint" && item is JsonValue v && v.TryGetValue<string>(out var text)
                        && (text.StartsWith('/') || text.StartsWith('@') || text.StartsWith('\\') || text.StartsWith("file:", StringComparison.OrdinalIgnoreCase)
                            || text.StartsWith("unix:", StringComparison.OrdinalIgnoreCase) || text.StartsWith("pipe", StringComparison.OrdinalIgnoreCase)
                            || (text.Length > 1 && text[1] == ':' && char.IsLetter(text[0]) && (text.Length == 2 || text[2] == '\\' || text[2] == '/'))))
                        return true;
                    if (ContainsFileReference(item)) return true;
                }
                return false;
            case JsonArray list:
                return list.Any(ContainsFileReference);
            default:
                return false;
        }
    }
}
