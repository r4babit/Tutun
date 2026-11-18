using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Tutun.Core;

public sealed class LinkException(string message) : Exception(message)
{
    public static LinkException Unsupported(string s) => new($"не поддерживается: {s}");
    public static LinkException Malformed(string s) => new($"ссылка повреждена: {s}");
}

public sealed class ParsedBatch
{
    public List<Server> Servers { get; } = new();
    public List<RoutingProfile> Profiles { get; } = new();
    public List<string> Errors { get; } = new();
}

/// Части ссылки вида scheme://user:pass@host:port/path?query#fragment.
public sealed class UrlParts
{
    public string Scheme = "", Host = "", Path = "";
    public string? User, Password, Fragment;
    public int? Port;
    public Dictionary<string, string> Query = new();

    public static UrlParts? Parse(string link)
    {
        var i = link.IndexOf("://", StringComparison.Ordinal);
        if (i <= 0) return null;
        var u = new UrlParts { Scheme = link[..i].ToLowerInvariant() };
        var rest = link[(i + 3)..];
        var hash = rest.IndexOf('#');
        if (hash >= 0) { u.Fragment = Decode(rest[(hash + 1)..]); rest = rest[..hash]; }
        var qm = rest.IndexOf('?');
        if (qm >= 0)
        {
            foreach (var pair in rest[(qm + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = pair.IndexOf('=');
                var k = Decode(eq >= 0 ? pair[..eq] : pair);
                u.Query[k] = eq >= 0 ? Decode(pair[(eq + 1)..]) : "";
            }
            rest = rest[..qm];
        }
        var slash = rest.IndexOf('/');
        if (slash >= 0) { u.Path = rest[slash..]; rest = rest[..slash]; }
        var at = rest.LastIndexOf('@');
        if (at >= 0)
        {
            var info = rest[..at];
            rest = rest[(at + 1)..];
            var colon = info.IndexOf(':');
            if (colon >= 0) { u.User = Decode(info[..colon]); u.Password = Decode(info[(colon + 1)..]); }
            else u.User = Decode(info);
        }
        if (rest.StartsWith('['))
        {
            var close = rest.IndexOf(']');
            if (close < 0) return null;
            u.Host = rest[1..close];
            rest = rest[(close + 1)..];
            if (rest.StartsWith(':')) { if (!int.TryParse(rest[1..], out var p)) return null; u.Port = p; }
            else if (rest.Length > 0) return null;
        }
        else
        {
            var colon = rest.LastIndexOf(':');
            if (colon >= 0)
            {
                if (!int.TryParse(rest[(colon + 1)..], out var p)) return null;
                u.Port = p; u.Host = rest[..colon];
            }
            else u.Host = rest;
        }
        if (u.Port is < 0 or > 65535) return null;
        return u;
    }

    public static string Decode(string s)
    {
        try { return Uri.UnescapeDataString(s); } catch { return s; }
    }

    public string? Q(string k) => Query.TryGetValue(k, out var v) && v.Length > 0 ? v : null;
}

/// Разбор ссылок vless/vmess/trojan/ss/hysteria2/tuic/wireguard/socks.
/// Сервер получает готовый outbound: для xray или (TUIC, Hysteria2 с obfs/insecure) для вспомогательного sing-box.
public static class LinkParser
{
    public static Server Parse(string raw, Guid? subscriptionID = null)
    {
        var link = raw.Trim();
        var i = link.IndexOf("://", StringComparison.Ordinal);
        if (i <= 0) throw LinkException.Malformed("нет схемы");
        var scheme = link[..i].ToLowerInvariant();
        Server server = scheme switch
        {
            "vless" => ParseStd(link, "vless"),
            "trojan" => ParseStd(link, "trojan"),
            "vmess" => ParseVmess(link),
            "ss" => ParseSS(link),
            "hysteria2" or "hy2" => ParseHy2(link),
            "tuic" => ParseTUIC(link),
            "wireguard" or "wg" => ParseWireGuard(link),
            "socks" or "socks5" => ParseSocks(link),
            "awg" or "amneziawg" => throw LinkException.Unsupported("AmneziaWG (его не умеет ни xray, ни sing-box)"),
            "happ" when link.StartsWith("happ://crypt", StringComparison.OrdinalIgnoreCase)
                => throw LinkException.Unsupported("зашифрованная ссылка Happ — открывается только в Happ"),
            _ => throw LinkException.Unsupported(scheme),
        };
        server.Id = StableID(link);
        server.SubscriptionID = subscriptionID;
        server.RawLink = link;
        server.Name = UrlParts.Decode(server.Name);
        return server;
    }

    /// Тело подписки или вставленный текст: base64-список, ссылки построчно, JSON с конфигами xray, профили маршрутов.
    public static ParsedBatch ParseBatch(string body, Guid? subscriptionID)
    {
        var text = body.Trim().TrimStart('﻿');
        if (!text.Contains("://") && !text.StartsWith('[') && !text.StartsWith('{') && !text.Contains("[Interface]")
            && Base64Decode(text) is { } decoded)
            text = decoded.Trim();
        var outp = new ParsedBatch();
        if (text.Contains("[Interface]") && text.Contains("[Peer]"))
        {
            try { outp.Servers.Add(ParseWireGuardConf(text, "WireGuard")); }
            catch (Exception e) { outp.Errors.Add("WireGuard: " + e.Message); }
            return outp;
        }
        if (text.StartsWith('[') || text.StartsWith('{'))
        {
            ParseJSONConfigs(text, subscriptionID, outp);
            return outp;
        }
        foreach (var line in text.Split('\n'))
        {
            var l = line.Trim();
            if (l.Length == 0 || l.StartsWith('#') || l.StartsWith("//")) continue;
            if (RoutingProfiles.ParseLink(l) is { } p) { p.FromSubscription = subscriptionID; outp.Profiles.Add(p); continue; }
            var lower = l.ToLowerInvariant();
            if (lower.StartsWith("happ://add/") || lower.StartsWith("tutun://add/")) continue;
            try { outp.Servers.Add(Parse(l, subscriptionID)); }
            catch (Exception e)
            {
                var hash = l.IndexOf('#');
                var name = hash >= 0 ? UrlParts.Decode(l[(hash + 1)..]) : l[..Math.Min(16, l.Length)];
                outp.Errors.Add($"{name}: {e.Message}");
            }
        }
        return outp;
    }

    static readonly HashSet<string> SkipProtocols = ["freedom", "blackhole", "dns", "loopback"];

    static void ParseJSONConfigs(string text, Guid? subscriptionID, ParsedBatch outp)
    {
        var node = Json.Parse(text);
        if (node == null) { outp.Errors.Add("JSON не читается"); return; }
        var configs = node is JsonArray arr ? arr.OfType<JsonObject>().ToList() : [node as JsonObject ?? new JsonObject()];
        for (int i = 0; i < configs.Count; i++)
        {
            var cfg = configs[i];
            var outs = (cfg.Arr("outbounds") ?? []).OfType<JsonObject>().Where(o => !SkipProtocols.Contains(o.Str("protocol") ?? "")).ToList();
            var chosen = outs.FirstOrDefault(o => o.Str("tag") == "proxy") ?? outs.FirstOrDefault();
            if (chosen == null) { outp.Errors.Add($"конфиг {i + 1}: нет сервера"); continue; }
            var ob = chosen.Clone();
            ob.Remove("tag");
            ob.Obj("streamSettings")?.Obj("sockopt")?.Remove("dialerProxy");
            var (host, port) = Endpoint(ob);
            var name = cfg.Str("remarks") ?? $"Сервер {i + 1}";
            var net = ob.Obj("streamSettings")?.Str("network") ?? "tcp";
            var json = Json.ToJSON(ob);
            outp.Servers.Add(new Server
            {
                Id = StableID(json), Name = name, Proto = ob.Str("protocol") ?? "?", Host = host, Port = port,
                Transport = net, OutboundJSON = json, SubscriptionID = subscriptionID,
            });
        }
    }

    public static (string, int) Endpoint(JsonObject ob)
    {
        var s = ob.Obj("settings");
        var v = (s.Arr("vnext") ?? s.Arr("servers"))?.FirstOrDefault() as JsonObject;
        if (v != null) return (v.Str("address") ?? "", v.Int("port") ?? 0);
        return (s.Str("address") ?? "", s.Int("port") ?? 0);
    }

    // vless / trojan

    static Server ParseStd(string link, string proto)
    {
        var u = UrlParts.Parse(link);
        if (u == null || u.Host.Length == 0 || u.Port == null) throw LinkException.Malformed(proto);
        var cred = u.User ?? "";
        if (cred.Length == 0) throw LinkException.Malformed($"{proto}: нет ключа");
        var addr = u.Host;
        var ob = new JsonObject { ["protocol"] = proto };
        if (proto == "vless")
        {
            var user = new JsonObject { ["id"] = cred, ["encryption"] = u.Q("encryption") ?? "none" };
            if (u.Q("flow") is { } flow) user["flow"] = flow;
            ob["settings"] = new JsonObject { ["vnext"] = new JsonArray(new JsonObject { ["address"] = addr, ["port"] = u.Port, ["users"] = new JsonArray(user) }) };
        }
        else
        {
            ob["settings"] = new JsonObject { ["servers"] = new JsonArray(new JsonObject { ["address"] = addr, ["port"] = u.Port, ["password"] = cred }) };
        }
        var net = NormalizeNetwork(u.Query.GetValueOrDefault("type", "tcp"));
        var security = u.Query.TryGetValue("security", out var sec) ? sec : (proto == "trojan" ? "tls" : "none");
        ob["streamSettings"] = StreamSettings(net, security, u.Query, addr);
        return new Server { Name = u.Fragment ?? addr, Proto = proto, Host = addr, Port = u.Port.Value, Transport = net, OutboundJSON = Json.ToJSON(ob) };
    }

    // vmess

    static Server ParseVmess(string link)
    {
        var body = link["vmess://".Length..];
        var decoded = Base64Decode(body);
        var obj = decoded == null ? null : Json.ParseObject(decoded);
        if (obj == null) throw LinkException.Malformed("vmess");
        string S(string k) => obj[k] switch { null => "", JsonValue v when v.TryGetValue<string>(out var s) => s, var v => v.ToJsonString().Trim('"') };
        var host = S("add");
        if (!int.TryParse(S("port"), out var port) || host.Length == 0) throw LinkException.Malformed("vmess");
        var q = new Dictionary<string, string>
        {
            ["path"] = S("path"), ["host"] = S("host"), ["sni"] = S("sni"), ["alpn"] = S("alpn"), ["fp"] = S("fp"), ["headerType"] = S("type"),
        };
        if (S("net") == "grpc") { q["serviceName"] = S("path"); q["mode"] = S("type") == "multi" ? "multi" : "gun"; }
        var net = NormalizeNetwork(S("net").Length == 0 ? "tcp" : S("net"));
        var security = S("tls") == "tls" ? "tls" : (S("tls") == "reality" ? "reality" : "none");
        var user = new JsonObject { ["id"] = S("id"), ["alterId"] = int.TryParse(S("aid"), out var aid) ? aid : 0, ["security"] = S("scy").Length == 0 ? "auto" : S("scy") };
        var ob = new JsonObject
        {
            ["protocol"] = "vmess",
            ["settings"] = new JsonObject { ["vnext"] = new JsonArray(new JsonObject { ["address"] = host, ["port"] = port, ["users"] = new JsonArray(user) }) },
            ["streamSettings"] = StreamSettings(net, security, q, host),
        };
        return new Server { Name = S("ps").Length == 0 ? host : S("ps"), Proto = "vmess", Host = host, Port = port, Transport = net, OutboundJSON = Json.ToJSON(ob) };
    }

    // shadowsocks

    static Server ParseSS(string link)
    {
        var body = link["ss://".Length..];
        var name = "";
        var hash = body.IndexOf('#');
        if (hash >= 0) { name = UrlParts.Decode(body[(hash + 1)..]); body = body[..hash]; }
        var qm = body.IndexOf('?');
        if (qm >= 0)
        {
            if (body[(qm + 1)..].Contains("plugin=")) throw LinkException.Unsupported("Shadowsocks с плагином");
            body = body[..qm];
        }
        string userinfo, hostport;
        var at = body.LastIndexOf('@');
        if (at >= 0)
        {
            userinfo = body[..at]; hostport = body[(at + 1)..];
            var dec = Base64Decode(UrlParts.Decode(userinfo));
            userinfo = dec != null && dec.Contains(':') ? dec : UrlParts.Decode(userinfo);
        }
        else
        {
            var dec = Base64Decode(body);
            var at2 = dec?.LastIndexOf('@') ?? -1;
            if (dec == null || at2 < 0) throw LinkException.Malformed("ss");
            userinfo = dec[..at2]; hostport = dec[(at2 + 1)..];
        }
        hostport = hostport.Trim('/');
        var colon = userinfo.IndexOf(':');
        var pcolon = hostport.LastIndexOf(':');
        if (colon < 0 || pcolon < 0 || !int.TryParse(hostport[(pcolon + 1)..], out var port)) throw LinkException.Malformed("ss");
        var method = userinfo[..colon]; var password = userinfo[(colon + 1)..];
        var host = hostport[..pcolon].Trim('[', ']');
        var ob = new JsonObject
        {
            ["protocol"] = "shadowsocks",
            ["settings"] = new JsonObject { ["servers"] = new JsonArray(new JsonObject { ["address"] = host, ["port"] = port, ["method"] = method, ["password"] = password }) },
        };
        return new Server { Name = name.Length == 0 ? host : name, Proto = "shadowsocks", Host = host, Port = port, Transport = "tcp", OutboundJSON = Json.ToJSON(ob) };
    }

    // hysteria2

    static Server ParseHy2(string link)
    {
        var normalized = link.StartsWith("hy2://", StringComparison.OrdinalIgnoreCase) ? "hysteria2://" + link[6..] : link;
        var u = UrlParts.Parse(normalized);
        if (u == null || u.Host.Length == 0) throw LinkException.Malformed("hysteria2");
        var port = u.Port ?? 443;
        var auth = u.User ?? "";
        if (u.Password != null) auth += ":" + u.Password;
        var addr = u.Host;
        var sni = u.Q("sni") ?? addr;
        var obfs = u.Q("obfs") is { } o && o != "none" ? o : null;
        var insecure = u.Query.GetValueOrDefault("insecure") == "1" || u.Query.GetValueOrDefault("allowInsecure") == "1";
        var name = u.Fragment ?? addr;

        // obfs (salamander), insecure, порт-хоппинг — через sing-box.
        if (obfs != null || insecure || u.Query.ContainsKey("mport"))
        {
            var ob = new JsonObject
            {
                ["type"] = "hysteria2", ["server"] = addr, ["server_port"] = port, ["password"] = auth,
                ["tls"] = new JsonObject { ["enabled"] = true, ["server_name"] = sni, ["insecure"] = insecure, ["alpn"] = Json.StrArray(["h3"]) },
            };
            if (obfs != null) ob["obfs"] = new JsonObject { ["type"] = obfs, ["password"] = u.Query.GetValueOrDefault("obfs-password", "") };
            if (int.TryParse(u.Query.GetValueOrDefault("upmbps"), out var up)) ob["up_mbps"] = up;
            if (int.TryParse(u.Query.GetValueOrDefault("downmbps"), out var down)) ob["down_mbps"] = down;
            if (u.Q("mport") is { } mport) ob["server_ports"] = Json.StrArray(PortRanges(mport));
            return new Server { Name = name, Proto = "hysteria2", Host = addr, Port = port, Transport = "quic", OutboundJSON = Json.ToJSON(ob), Engine = Engine.Singbox };
        }
        var tls = new JsonObject { ["serverName"] = sni, ["alpn"] = Json.StrArray(["h3"]) };
        if (u.Q("pinSHA256") is { } pin) tls["pinnedPeerCertSha256"] = pin;
        var xob = new JsonObject
        {
            ["protocol"] = "hysteria",
            ["settings"] = new JsonObject { ["version"] = 2, ["address"] = addr, ["port"] = port },
            ["streamSettings"] = new JsonObject
            {
                ["network"] = "hysteria", ["security"] = "tls", ["tlsSettings"] = tls,
                ["hysteriaSettings"] = new JsonObject { ["version"] = 2, ["auth"] = auth },
            },
        };
        return new Server { Name = name, Proto = "hysteria2", Host = addr, Port = port, Transport = "quic", OutboundJSON = Json.ToJSON(xob) };
    }

    /// mport «443,20000-30000» → sing-box server_ports «443:443», «20000:30000».
    /// Одиночный порт sing-box без двоеточия не принимает (bad port range) — как исправлено на маке.
    static List<string> PortRanges(string mport)
    {
        var outp = new List<string>();
        foreach (var raw in mport.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = raw.Trim().Replace('-', ':').Split(':');
            if (parts.Length is < 1 or > 2 || !parts.All(p => int.TryParse(p, out var n) && n is >= 1 and <= 65535))
                throw LinkException.Malformed("hysteria2: неверный mport");
            outp.Add(parts.Length == 1 ? $"{parts[0]}:{parts[0]}" : $"{parts[0]}:{parts[1]}");
        }
        return outp;
    }

    // TUIC (sing-box)

    static Server ParseTUIC(string link)
    {
        var u = UrlParts.Parse(link);
        if (u == null || u.Host.Length == 0 || u.Port == null) throw LinkException.Malformed("tuic");
        var uuid = u.User ?? "";
        if (uuid.Length == 0) throw LinkException.Malformed("tuic: нет uuid");
        var alpn = (u.Q("alpn") ?? "h3").Split(',');
        var ob = new JsonObject
        {
            ["type"] = "tuic", ["server"] = u.Host, ["server_port"] = u.Port, ["uuid"] = uuid, ["password"] = u.Password ?? "",
            ["congestion_control"] = u.Query.GetValueOrDefault("congestion_control", "bbr"),
            ["udp_relay_mode"] = u.Query.GetValueOrDefault("udp_relay_mode", "native"),
            ["tls"] = new JsonObject
            {
                ["enabled"] = true, ["server_name"] = u.Q("sni") ?? u.Host,
                ["insecure"] = u.Query.GetValueOrDefault("allow_insecure") == "1" || u.Query.GetValueOrDefault("insecure") == "1",
                ["alpn"] = Json.StrArray(alpn),
            },
        };
        return new Server { Name = u.Fragment ?? u.Host, Proto = "tuic", Host = u.Host, Port = u.Port.Value, Transport = "quic", OutboundJSON = Json.ToJSON(ob), Engine = Engine.Singbox };
    }

    // WireGuard (xray)

    static Server ParseWireGuard(string link)
    {
        var u = UrlParts.Parse(link);
        if (u == null || u.Host.Length == 0 || u.Port == null) throw LinkException.Malformed("wireguard");
        var secret = !string.IsNullOrEmpty(u.User) ? u.User : u.Query.GetValueOrDefault("privatekey", "");
        var pub = u.Query.GetValueOrDefault("publickey") ?? u.Query.GetValueOrDefault("public_key");
        if (secret.Length == 0 || pub == null) throw LinkException.Malformed("wireguard: нет ключей");
        var addresses = (u.Query.GetValueOrDefault("address") ?? u.Query.GetValueOrDefault("ip") ?? "10.0.0.2/32").Split(',')
            .Select(s => s.Trim()).Select(t => t.Contains('/') ? t : (t.Contains(':') ? t + "/128" : t + "/32")).ToList();
        return WireGuardServer(u.Fragment ?? u.Host, u.Host, u.Port.Value, secret, pub,
            u.Query.GetValueOrDefault("presharedkey") ?? u.Query.GetValueOrDefault("psk"), addresses,
            int.TryParse(u.Query.GetValueOrDefault("mtu"), out var mtu) ? mtu : null, u.Query.GetValueOrDefault("reserved"));
    }

    public static Server ParseWireGuardConf(string text, string name)
    {
        string section = "";
        var iface = new Dictionary<string, string>(); var peer = new Dictionary<string, string>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('[')) { section = line.ToLowerInvariant(); continue; }
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var k = line[..eq].Trim().ToLowerInvariant();
            var v = line[(eq + 1)..].Trim();
            if (section == "[interface]") iface[k] = v; else if (section == "[peer]") peer[k] = v;
        }
        if (iface.Keys.Any(k => k is "jc" or "jmin" or "jmax" or "s1" or "s2" or "h1"))
            throw LinkException.Unsupported("AmneziaWG (его не умеет ни xray, ни sing-box)");
        if (!iface.TryGetValue("privatekey", out var secret) || !peer.TryGetValue("publickey", out var pub) || !peer.TryGetValue("endpoint", out var ep))
            throw LinkException.Malformed("конфиг WireGuard");
        var colon = ep.LastIndexOf(':');
        if (colon < 0 || !int.TryParse(ep[(colon + 1)..], out var port)) throw LinkException.Malformed("конфиг WireGuard");
        var host = ep[..colon].Trim('[', ']');
        var addrs = iface.GetValueOrDefault("address", "10.0.0.2/32").Split(',').Select(s => s.Trim()).ToList();
        var s = WireGuardServer(name, host, port, secret, pub, peer.GetValueOrDefault("presharedkey"), addrs,
            int.TryParse(iface.GetValueOrDefault("mtu"), out var mtu) ? mtu : null, null);
        s.Id = StableID(text);
        return s;
    }

    static Server WireGuardServer(string name, string host, int port, string secret, string publicKey, string? psk,
                                  List<string> addresses, int? mtu, string? reserved)
    {
        var peer = new JsonObject { ["publicKey"] = publicKey, ["endpoint"] = $"{host}:{port}", ["allowedIPs"] = Json.StrArray(["0.0.0.0/0", "::/0"]) };
        if (!string.IsNullOrEmpty(psk)) peer["preSharedKey"] = psk;
        var settings = new JsonObject { ["secretKey"] = secret, ["address"] = Json.StrArray(addresses), ["peers"] = new JsonArray(peer), ["mtu"] = mtu ?? 1420 };
        var r = reserved?.Split(',').Select(x => int.TryParse(x.Trim(), out var n) ? (int?)n : null).Where(x => x != null).ToList();
        if (r is { Count: 3 }) settings["reserved"] = new JsonArray(r.Select(x => (JsonNode?)JsonValue.Create(x!.Value)).ToArray());
        var ob = new JsonObject { ["protocol"] = "wireguard", ["settings"] = settings };
        return new Server { Name = name, Proto = "wireguard", Host = host, Port = port, Transport = "udp", OutboundJSON = Json.ToJSON(ob) };
    }

    // SOCKS

    static Server ParseSocks(string link)
    {
        var l = link;
        var start = l.IndexOf("://", StringComparison.Ordinal) + 3;
        var at = l.IndexOf('@');
        if (at > start)
        {
            var cred = l[start..at];
            if (!cred.Contains(':') && Base64Decode(UrlParts.Decode(cred)) is { } dec && dec.Contains(':'))
            {
                var c = dec.IndexOf(':');
                l = l[..start] + Uri.EscapeDataString(dec[..c]) + ":" + Uri.EscapeDataString(dec[(c + 1)..]) + l[at..];
            }
        }
        var u = UrlParts.Parse(l);
        if (u == null || u.Host.Length == 0 || u.Port == null) throw LinkException.Malformed("socks");
        var server = new JsonObject { ["address"] = u.Host, ["port"] = u.Port };
        if (!string.IsNullOrEmpty(u.User)) server["users"] = new JsonArray(new JsonObject { ["user"] = u.User, ["pass"] = u.Password ?? "" });
        var ob = new JsonObject { ["protocol"] = "socks", ["settings"] = new JsonObject { ["servers"] = new JsonArray(server) } };
        return new Server { Name = u.Fragment ?? u.Host, Proto = "socks", Host = u.Host, Port = u.Port.Value, Transport = "tcp", OutboundJSON = Json.ToJSON(ob) };
    }

    // transport / security

    public static string NormalizeNetwork(string n) => n.ToLowerInvariant() switch
    {
        "" or "tcp" or "raw" => "tcp",
        "splithttp" or "h2" or "http" => "xhttp",
        var x => x,
    };

    static JsonObject StreamSettings(string network, string security, Dictionary<string, string> q, string address)
    {
        string? V(string k) => q.TryGetValue(k, out var x) && x.Length > 0 ? x : null;
        var ss = new JsonObject { ["network"] = network };
        switch (network)
        {
            case "ws":
                var w = new JsonObject { ["path"] = V("path") ?? "/" };
                if (V("host") is { } wh) w["host"] = wh;
                ss["wsSettings"] = w; break;
            case "grpc":
                var g = new JsonObject { ["serviceName"] = V("serviceName") ?? V("path") ?? "", ["multiMode"] = q.GetValueOrDefault("mode") == "multi" };
                if (V("authority") is { } a) g["authority"] = a;
                ss["grpcSettings"] = g; break;
            case "xhttp":
                var x = new JsonObject { ["path"] = V("path") ?? "/", ["mode"] = V("mode") ?? "auto" };
                if (V("host") is { } xh) x["host"] = xh;
                if (V("extra") is { } e && Json.Parse(e) is { } extra) x["extra"] = extra;
                ss["xhttpSettings"] = x; break;
            case "httpupgrade":
                var h = new JsonObject { ["path"] = V("path") ?? "/" };
                if (V("host") is { } hh) h["host"] = hh;
                ss["httpupgradeSettings"] = h; break;
            case "kcp":
                var k = new JsonObject { ["header"] = new JsonObject { ["type"] = V("headerType") ?? "none" } };
                if (V("seed") is { } seed) k["seed"] = seed;
                ss["kcpSettings"] = k; break;
            default:
                if (V("headerType") == "http")
                {
                    var req = new JsonObject { ["path"] = Json.StrArray([V("path") ?? "/"]) };
                    if (V("host") is { } th) req["headers"] = new JsonObject { ["Host"] = Json.StrArray(th.Split(',')) };
                    ss["tcpSettings"] = new JsonObject { ["header"] = new JsonObject { ["type"] = "http", ["request"] = req } };
                }
                break;
        }
        var alpn = V("alpn")?.Split(',');
        switch (security)
        {
            case "tls":
                var t = new JsonObject { ["serverName"] = V("sni") ?? V("host") ?? address };
                if (V("fp") is { } fp) t["fingerprint"] = fp;
                if (alpn != null) t["alpn"] = Json.StrArray(alpn);
                // allowInsecure в xray 26 удалён: доверие к сертификату — только через pcs/vcn из ссылки.
                if (V("pcs") is { } pin) t["pinnedPeerCertSha256"] = pin;
                if (V("vcn") is { } vcn) t["verifyPeerCertByName"] = vcn;
                if (V("ech") is { } ech) t["echConfigList"] = ech;
                ss["security"] = "tls"; ss["tlsSettings"] = t; break;
            case "reality":
                var r = new JsonObject
                {
                    ["serverName"] = V("sni") ?? "", ["fingerprint"] = V("fp") ?? "chrome", ["publicKey"] = V("pbk") ?? "", ["shortId"] = V("sid") ?? "",
                };
                if (V("spx") is { } spx) r["spiderX"] = spx;
                if (V("pqv") is { } pqv) r["mldsa65Verify"] = pqv;
                ss["security"] = "reality"; ss["realitySettings"] = r; break;
            default:
                ss["security"] = "none"; break;
        }
        return ss;
    }

    /// Почему xray не примет этот сервер (null — примет).
    /// xray 26 запрещает VLESS без TLS/Reality и без VLESS Encryption на публичный адрес.
    public static string? RejectReason(Server s)
    {
        if (s.Engine != Engine.Xray) return null;
        var ob = s.Outbound;
        if (ob.Str("protocol") != "vless") return null;
        if ((ob.Obj("streamSettings").Str("security") ?? "none") != "none") return null;
        var user = (ob.Obj("settings").Arr("vnext")?.FirstOrDefault() as JsonObject).Arr("users")?.FirstOrDefault() as JsonObject;
        if ((user.Str("encryption") ?? "none") != "none") return null;
        if (IsPrivateHost(s.Host)) return null;
        return "без шифрования — новая версия xray такие запрещает";
    }

    public static bool IsPrivateHost(string h)
    {
        var host = h.ToLowerInvariant();
        if (host == "localhost" || host.EndsWith(".local") || host.EndsWith(".lan")) return true;
        var p = host.Split('.').Select(x => int.TryParse(x, out var n) ? n : -1).ToArray();
        if (p.Length == 4 && p.All(n => n >= 0))
            return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] is >= 16 and <= 31)
                   || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && p[1] is >= 64 and <= 127);
        return host.StartsWith("fd") || host.StartsWith("fe80") || host == "::1";
    }

    public static string? Base64Decode(string s)
    {
        var t = s.Trim().Replace("\n", "").Replace("\r", "").Replace('-', '+').Replace('_', '/');
        if (t.Length == 0) return null;
        while (t.Length % 4 != 0) t += "=";
        try
        {
            var bytes = Convert.FromBase64String(t);
            var str = new UTF8Encoding(false, true).GetString(bytes);
            return str;
        }
        catch { return null; }
    }

    public static string StableID(string s) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(s))[..8]);
}
