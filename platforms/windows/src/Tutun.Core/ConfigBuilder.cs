using System.Net;
using System.Text.Json.Nodes;

namespace Tutun.Core;

/// Готовый набор конфигов для службы.
public sealed record BuiltConfig(string Xray, string? SingBox, string? Helper, List<Server> Servers);

/// Описание подключения: всё, что служба принимает от окна. Конфиги служба собирает сама.
public sealed class ConnectionInput
{
    public List<Server> Servers { get; set; } = new();     // p0…pN; при ручном выборе с подстраховкой p0 — выбранный
    public AppSettings Settings { get; set; } = new();
    public RoutingProfile? Profile { get; set; }
    public Server? Chain { get; set; }                      // первый узел цепочки
    public bool FailoverOnly { get; set; }
    public string ClashSecret { get; set; } = "";
    public List<string> ExtraDirectProcesses { get; set; } = new();
}

/// Собирает конфиги xray (выбор сервера, маршруты), sing-box (перехват трафика Windows через wintun)
/// и вспомогательного sing-box (TUIC, Hysteria2 с obfs).
public static class ConfigBuilder
{
    /// Пути ядер, которые пускаются мимо TUN. Служба передаёт свои, тесты — подставные.
    public static string[] CorePaths = [Paths.Xray, Paths.SingBox];

    /// Коды из geoip.dat / geosite.dat службы (null — не проверять). Ссылки «geoip:xx» / «geosite:xx» на отсутствующие коды
    /// отбрасываются во всех правилах (страна, свои списки, профили провайдера, DNS): иначе xray не запускается.
    /// Базы бывают разные: в полной runetfreedom нет blacklist-ru, in-ru и т.п., в урезанной — tr, ae, mm.
    public static HashSet<string>? GeoipCodes, GeositeCodes;
    /// Что пропустили при последней сборке — служба пишет это в журнал.
    public static readonly List<string> Skipped = new();

    static string[] AvailableIps(IEnumerable<string> ips) => Filter(ips, "geoip:", GeoipCodes);
    static string[] AvailableDomains(IEnumerable<string> domains) => Filter(domains, "geosite:", GeositeCodes);

    static string[] Filter(IEnumerable<string> items, string prefix, HashSet<string>? codes)
    {
        var outp = new List<string>();
        foreach (var it in items)
        {
            var t = it.Trim();
            // «!» в начале (исключение) и «@атрибут» в конце к коду не относятся.
            var body = t.TrimStart('!');
            if (codes != null && body.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                var code = body[prefix.Length..].Split('@')[0];
                if (!codes.Contains(code)) { lock (Skipped) if (!Skipped.Contains(t)) Skipped.Add(t); continue; }
            }
            outp.Add(t);
        }
        return outp.ToArray();
    }

    public static BuiltConfig Build(ConnectionInput input)
    {
        var helper = HelperConfig(input.Servers);
        var x = Xray(input);
        var sb = input.Settings.Mode == ConnectionMode.Tun ? SingBox(input) : null;
        return new BuiltConfig(x, sb, helper, input.Servers);
    }

    static readonly HashSet<string> TcpTransports = ["tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade"];

    public static string Xray(ConnectionInput input)
    {
        var s = input.Settings; var servers = input.Servers;
        if (servers.Count == 0) throw new InvalidOperationException("нет серверов");
        var outbounds = new JsonArray();
        int helperIndex = 0;
        var useChain = input.Chain != null && input.Chain.Engine == Engine.Xray;
        var useFrag = s.Fragment || s.Noises;

        for (int i = 0; i < servers.Count; i++)
        {
            var srv = servers[i];
            JsonObject ob;
            if (srv.Engine == Engine.Singbox)
            {
                ob = new JsonObject
                {
                    ["protocol"] = "socks",
                    ["settings"] = new JsonObject { ["servers"] = new JsonArray(new JsonObject { ["address"] = "127.0.0.1", ["port"] = Paths.HelperBasePort + helperIndex }) },
                };
                helperIndex++;
            }
            else
            {
                ob = srv.Outbound;
                var proto = ob.Str("protocol") ?? "";
                var ss = ob.Obj("streamSettings") ?? new JsonObject();
                var net = ss.Str("network") ?? "tcp";
                var tcpBased = TcpTransports.Contains(net) && proto is "vless" or "vmess" or "trojan" or "shadowsocks" or "socks";
                if (useChain || (useFrag && tcpBased))
                {
                    var so = ss.Obj("sockopt") ?? new JsonObject();
                    so["dialerProxy"] = useChain ? "chain" : "fragment";
                    ss["sockopt"] = so;
                    ss["network"] ??= "tcp";
                    ob["streamSettings"] = ss;
                }
                if (s.Mux && tcpBased && net != "xhttp" && !HasFlow(ob))
                    ob["mux"] = new JsonObject { ["enabled"] = true, ["concurrency"] = Math.Max(1, s.MuxConcurrency), ["xudpConcurrency"] = 16, ["xudpProxyUDP443"] = "reject" };
            }
            ob["tag"] = $"p{i}";
            outbounds.Add(ob);
        }
        if (useChain)
        {
            var c = input.Chain!.Outbound;
            c["tag"] = "chain";
            if (useFrag && c.Obj("streamSettings") is { } css && TcpTransports.Contains(css.Str("network") ?? "tcp"))
            {
                var so = css.Obj("sockopt") ?? new JsonObject(); so["dialerProxy"] = "fragment"; css["sockopt"] = so;
            }
            outbounds.Add(c);
        }
        if (useFrag)
        {
            var fs = new JsonObject();
            if (s.Fragment) fs["fragment"] = new JsonObject { ["packets"] = s.FragmentPackets, ["length"] = s.FragmentLength, ["interval"] = s.FragmentInterval };
            if (s.Noises) fs["noises"] = new JsonArray(new JsonObject { ["type"] = "rand", ["packet"] = "10-20", ["delay"] = "10-16" });
            outbounds.Add(new JsonObject { ["tag"] = "fragment", ["protocol"] = "freedom", ["settings"] = fs });
        }
        outbounds.Add(new JsonObject { ["tag"] = "direct", ["protocol"] = "freedom" });
        outbounds.Add(new JsonObject { ["tag"] = "block", ["protocol"] = "blackhole" });

        var balanced = servers.Count > 1;
        JsonObject ProxyTarget(JsonObject r) { if (balanced) r["balancerTag"] = "auto"; else r["outboundTag"] = "p0"; return r; }
        var p = input.Profile;
        var rules = new JsonArray(new JsonObject { ["inboundTag"] = Json.StrArray(["api"]), ["outboundTag"] = "api" });
        // Пробные входы: через t{i} всегда идёт сервер p{i} — служба замеряет каждого кандидата отдельно.
        if (balanced)
            for (int i = 0; i < servers.Count; i++)
                rules.Add(new JsonObject { ["inboundTag"] = Json.StrArray([$"t{i}"]), ["outboundTag"] = $"p{i}" });

        if (s.RoutingMode == RoutingMode.Direct)
        {
            rules.Add(new JsonObject { ["network"] = "tcp,udp", ["outboundTag"] = "direct" });
        }
        else
        {
            var groups = new Dictionary<string,List<JsonObject>>
            {
                ["block"] = [], ["proxy"] = [], ["direct"] = []
            };
            // 1. Блокировка
            var blockDomains = Cleaned(s.BlockDomains).Concat(p?.BlockSites ?? []).ToList();
            if (s.BlockAds) blockDomains.Add("geosite:category-ads-all");
            var blockIPs = Cleaned(s.BlockIPs).Concat(p?.BlockIPs ?? []).ToList();
            if (AvailableDomains(blockDomains.Select(DomainRule)) is { Length: > 0 } bd) groups["block"].Add(new JsonObject { ["domain"] = Json.StrArray(bd), ["outboundTag"] = "block" });
            if (AvailableIps(blockIPs) is { Length: > 0 } bi) groups["block"].Add(new JsonObject { ["ip"] = Json.StrArray(bi), ["outboundTag"] = "block" });
            // 2. Всегда через VPN
            var proxyDomains = Cleaned(s.ProxyDomains).Concat(p?.ProxySites ?? []).ToList();
            var proxyIPs = Cleaned(s.ProxyIPs).Concat(p?.ProxyIPs ?? []).ToList();
            if (AvailableDomains(proxyDomains.Select(DomainRule)) is { Length: > 0 } pd) groups["proxy"].Add(ProxyTarget(new JsonObject { ["domain"] = Json.StrArray(pd) }));
            if (AvailableIps(proxyIPs) is { Length: > 0 } pi) groups["proxy"].Add(ProxyTarget(new JsonObject { ["ip"] = Json.StrArray(pi) }));
            // 3. Напрямую
            groups["direct"].Add(new JsonObject { ["ip"] = Json.StrArray(["geoip:private"]), ["outboundTag"] = "direct" });
            if (s.RoutingMode == RoutingMode.Rule)
            {
                var directDomains = Cleaned(s.DirectDomains).Concat(p?.DirectSites ?? []).ToList();
                var directIPs = Cleaned(s.DirectIPs).Concat(p?.DirectIPs ?? []).ToList();
                if (AvailableDomains(directDomains.Select(DomainRule)) is { Length: > 0 } dd) groups["direct"].Add(new JsonObject { ["domain"] = Json.StrArray(dd), ["outboundTag"] = "direct" });
                if (AvailableIps(directIPs) is { Length: > 0 } di) groups["direct"].Add(new JsonObject { ["ip"] = Json.StrArray(di), ["outboundTag"] = "direct" });
                if (s.RussiaDirect)
                {
                    var region = HomeRegions.Get(s.DirectCountry);
                    if (AvailableDomains(region.Domains) is { Length: > 0 } rd) groups["direct"].Add(new JsonObject { ["domain"] = Json.StrArray(rd), ["outboundTag"] = "direct" });
                    if (AvailableIps(region.Ips) is { Length: > 0 } ips)
                        groups["direct"].Add(new JsonObject { ["ip"] = Json.StrArray(ips), ["outboundTag"] = "direct" });
                }
            }
            foreach (var group in RoutingProfiles.RouteGroups(p?.RouteOrder) ?? ["block", "proxy", "direct"])
                foreach (var rule in groups[group]) rules.Add(rule);
            // 4. Остальное
            if (s.RoutingMode == RoutingMode.Rule && p != null && !p.GlobalProxy)
                rules.Add(new JsonObject { ["network"] = "tcp,udp", ["outboundTag"] = "direct" });
            else
                rules.Add(ProxyTarget(new JsonObject { ["network"] = "tcp,udp" }));
        }

        var routing = new JsonObject { ["domainStrategy"] = p?.DomainStrategy ?? s.DomainStrategy, ["rules"] = rules };
        if (balanced)
        {
            // Какой сервер из списка использовать, решает служба Tutun и задаёт ядру командой «api bo».
            routing["balancers"] = new JsonArray(new JsonObject
            {
                ["tag"] = "auto", ["selector"] = Json.StrArray(["p"]), ["strategy"] = new JsonObject { ["type"] = "random" },
            });
        }

        JsonObject Sniff() => new() { ["enabled"] = s.Sniffing, ["destOverride"] = Json.StrArray(["http", "tls", "quic"]), ["routeOnly"] = true };
        var inbounds = new JsonArray(
            new JsonObject { ["tag"] = "socks", ["listen"] = "127.0.0.1", ["port"] = Paths.SocksPort, ["protocol"] = "socks", ["settings"] = new JsonObject { ["udp"] = true }, ["sniffing"] = Sniff() },
            new JsonObject { ["tag"] = "http", ["listen"] = "127.0.0.1", ["port"] = Paths.HttpPort, ["protocol"] = "http", ["sniffing"] = Sniff() },
            new JsonObject { ["tag"] = "api", ["listen"] = "127.0.0.1", ["port"] = Paths.ApiPort, ["protocol"] = "dokodemo-door", ["settings"] = new JsonObject { ["address"] = "127.0.0.1" } });
        if (balanced)
            for (int i = 0; i < servers.Count; i++)
                inbounds.Add(new JsonObject { ["tag"] = $"t{i}", ["listen"] = "127.0.0.1", ["port"] = Paths.ProbeBasePort + i, ["protocol"] = "socks", ["settings"] = new JsonObject { ["udp"] = false } });
        if (s.AllowLAN)
        {
            if (string.IsNullOrWhiteSpace(s.LanUser) || string.IsNullOrWhiteSpace(s.LanPassword))
                throw new ValidationException("Для раздачи VPN нужны логин и пароль");
            var socks = new JsonObject { ["udp"] = true };
            var http = new JsonObject();
            socks["auth"] = "password";
            socks["accounts"] = new JsonArray(new JsonObject { ["user"] = s.LanUser, ["pass"] = s.LanPassword });
            http["accounts"] = new JsonArray(new JsonObject { ["user"] = s.LanUser, ["pass"] = s.LanPassword });
            inbounds.Add(new JsonObject { ["tag"] = "lan-socks", ["listen"] = "0.0.0.0", ["port"] = s.LanSocksPort, ["protocol"] = "socks", ["settings"] = socks, ["sniffing"] = Sniff() });
            inbounds.Add(new JsonObject { ["tag"] = "lan-http", ["listen"] = "0.0.0.0", ["port"] = s.LanHttpPort, ["protocol"] = "http", ["settings"] = http, ["sniffing"] = Sniff() });
        }

        var dnsServers = new JsonArray(JsonValue.Create(p?.RemoteDNS ?? s.RemoteDNS));
        if (s.RussiaDirect && s.RoutingMode == RoutingMode.Rule)
        {
            var region = HomeRegions.Get(s.DirectCountry);
            if (AvailableDomains(region.DnsDomains) is { Length: > 0 } dns) dnsServers.Add(new JsonObject { ["address"] = HomeRegions.DirectDns(region, p?.DirectDNS ?? s.DirectDNS), ["domains"] = Json.StrArray(dns) });
        }
        dnsServers.Add("localhost");

        var config = new JsonObject
        {
            // Журнал соединений xray пишет каждый запрос — включаем только в режиме «Отладка».
            ["log"] = new JsonObject { ["loglevel"] = s.LogLevel, ["access"] = s.LogLevel == "debug" ? "" : "none" },
            ["stats"] = new JsonObject(),
            ["api"] = new JsonObject { ["tag"] = "api", ["services"] = Json.StrArray(["StatsService", "RoutingService"]) },
            ["policy"] = new JsonObject { ["system"] = new JsonObject { ["statsOutboundUplink"] = true, ["statsOutboundDownlink"] = true } },
            ["dns"] = new JsonObject { ["servers"] = dnsServers, ["queryStrategy"] = s.Ipv6 ? "UseIP" : "UseIPv4" },
            ["inbounds"] = inbounds,
            ["outbounds"] = outbounds,
            ["routing"] = routing,
        };
        if (p?.DnsHosts is { Count: > 0 } hosts) config["dns"]!["hosts"] = System.Text.Json.JsonSerializer.SerializeToNode(hosts);
        return Json.ToJSON(config);
    }

    static bool HasFlow(JsonObject ob)
    {
        var user = (ob.Obj("settings").Arr("vnext")?.FirstOrDefault() as JsonObject).Arr("users")?.FirstOrDefault() as JsonObject;
        return !string.IsNullOrEmpty(user.Str("flow"));
    }

    /// Для серверов на sing-box: socks-вход 127.0.0.1:20000+k → этот сервер.
    public static string? HelperConfig(List<Server> servers, int basePort = Paths.HelperBasePort)
    {
        var hs = servers.Where(s => s.Engine == Engine.Singbox).ToList();
        if (hs.Count == 0) return null;
        var inbounds = new JsonArray(); var outbounds = new JsonArray(); var rules = new JsonArray();
        for (int k = 0; k < hs.Count; k++)
        {
            inbounds.Add(new JsonObject { ["type"] = "socks", ["tag"] = $"h{k}", ["listen"] = "127.0.0.1", ["listen_port"] = basePort + k });
            var ob = hs[k].Outbound; ob["tag"] = $"o{k}";
            outbounds.Add(ob);
            rules.Add(new JsonObject { ["inbound"] = Json.StrArray([$"h{k}"]), ["outbound"] = $"o{k}" });
        }
        outbounds.Add(new JsonObject { ["type"] = "direct", ["tag"] = "direct" });
        var cfg = new JsonObject
        {
            ["log"] = new JsonObject { ["level"] = "warn" }, ["inbounds"] = inbounds, ["outbounds"] = outbounds,
            ["route"] = new JsonObject { ["rules"] = rules, ["final"] = "direct", ["auto_detect_interface"] = true },
        };
        return Json.ToJSON(cfg);
    }

    /// sing-box TUN: весь трафик Windows → xray. Ядра, Tutun и исключённые приложения идут мимо.
    public static string SingBox(ConnectionInput input)
    {
        var s = input.Settings;
        var rules = new JsonArray(
            new JsonObject { ["action"] = "sniff" },
            new JsonObject { ["protocol"] = "dns", ["action"] = "hijack-dns" },
            new JsonObject { ["process_path"] = Json.StrArray(CorePaths), ["outbound"] = "direct" },
            new JsonObject { ["ip_is_private"] = true, ["outbound"] = "direct" });
        var ownProcesses = new List<string> { "Tutun.exe", "Tutun.Service.exe" };
        ownProcesses.AddRange(input.ExtraDirectProcesses);
        var final = "proxy";
        switch (s.AppsMode)
        {
            case AppsMode.Exclude:
                rules.Add(new JsonObject { ["process_name"] = Json.StrArray(ownProcesses.Concat(Cleaned(s.DirectApps).Select(ExeName))), ["outbound"] = "direct" });
                break;
            case AppsMode.Include:
                rules.Add(new JsonObject { ["process_name"] = Json.StrArray(ownProcesses), ["outbound"] = "direct" });
                var inc = Cleaned(s.IncludeApps).Select(ExeName).ToList();
                if (inc.Count > 0) { rules.Add(new JsonObject { ["process_name"] = Json.StrArray(inc), ["outbound"] = "proxy" }); final = "direct"; }
                break;
        }
        if (s.RoutingMode == RoutingMode.Direct) final = "direct";

        var tun = new JsonObject
        {
            ["type"] = "tun", ["tag"] = "tun", ["interface_name"] = Paths.TunName,
            // Не 172.19.0.1 (значение sing-box по умолчанию): его занимают туннели Happ и Hiddify.
            ["address"] = Json.StrArray(s.Ipv6 ? ["172.31.233.1/30", "fdfe:dcba:9233::1/126"] : ["172.31.233.1/30"]),
            ["mtu"] = 9000, ["auto_route"] = true, ["strict_route"] = true, ["stack"] = "mixed",
        };
        var excluded = Cleaned(s.ExcludedRoutes).Select(Cidr).Where(c => c != null).ToList();
        if (excluded.Count > 0) tun["route_exclude_address"] = Json.StrArray(excluded!);

        var remote = input.Profile?.RemoteDNS ?? s.RemoteDNS;
        var remoteServer = DnsServer(remote, "remote");
        remoteServer["detour"] = "proxy";
        // Имена самих VPN-серверов распознаём напрямую. На Windows ядра спрашивают DNS через системную службу (svchost),
        // её запрос попадает в туннель и без этого правила ушёл бы в ещё не поднятый VPN — замкнутый круг.
        var bootstrap = DnsServer(input.Profile?.DirectDNS ?? s.DirectDNS, "bootstrap");
        var serverHosts = input.Servers.Append(input.Chain).OfType<Server>().Select(x => x.Host.Trim().ToLowerInvariant())
            .Where(h => h.Length > 0 && !IPAddress.TryParse(h, out _)).Distinct().ToList();
        var dnsRules = new JsonArray();
        var dnsServers = new JsonArray(remoteServer, bootstrap, new JsonObject { ["type"] = "local", ["tag"] = "local" });
        if (input.Profile?.DnsHosts is { Count: > 0 } pinned)
        {
            var predefined = new JsonObject();
            foreach (var (domain, ip) in pinned) predefined[domain] = Json.StrArray([ip]);
            dnsServers.Add(new JsonObject { ["type"] = "hosts", ["tag"] = "pinned", ["predefined"] = predefined });
            dnsRules.Add(new JsonObject { ["domain"] = Json.StrArray(pinned.Keys.Order()), ["server"] = "pinned" });
        }
        if (serverHosts.Count > 0) dnsRules.Add(new JsonObject { ["domain"] = Json.StrArray(serverHosts), ["server"] = "bootstrap" });
        if (s.RussiaDirect && s.RoutingMode == RoutingMode.Rule)
        {
            var code = HomeRegions.Get(s.DirectCountry).Code;
            dnsRules.Add(new JsonObject { ["domain_suffix"] = Json.StrArray(code == "ru" ? ["ru", "su", "xn--p1ai"] : [code]), ["server"] = "bootstrap" });
        }
        var config = new JsonObject
        {
            ["log"] = new JsonObject { ["level"] = "warn", ["timestamp"] = true },
            ["dns"] = new JsonObject
            {
                ["servers"] = dnsServers,
                ["rules"] = dnsRules,
                ["final"] = s.RoutingMode == RoutingMode.Direct ? "bootstrap" : "remote",
                ["strategy"] = s.Ipv6 ? "prefer_ipv4" : "ipv4_only",
            },
            ["inbounds"] = new JsonArray(tun),
            ["outbounds"] = new JsonArray(
                new JsonObject { ["type"] = "socks", ["tag"] = "proxy", ["server"] = "127.0.0.1", ["server_port"] = Paths.SocksPort, ["version"] = "5" },
                new JsonObject { ["type"] = "direct", ["tag"] = "direct" }),
            ["route"] = new JsonObject
            {
                ["auto_detect_interface"] = true,
                ["default_domain_resolver"] = "bootstrap",
                ["final"] = final,
                ["rules"] = rules,
            },
            ["experimental"] = new JsonObject { ["clash_api"] = new JsonObject { ["external_controller"] = $"127.0.0.1:{Paths.ClashPort}", ["secret"] = input.ClashSecret } },
        };
        return Json.ToJSON(config);
    }

    /// Имя процесса для правил: «chrome» → «chrome.exe», путь → имя файла.
    static string ExeName(string s)
    {
        var name = Path.GetFileName(s.Trim());
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
    }

    /// «1.1.1.1» → DoH по IP (у Cloudflare/Google/Quad9), «https://…» → DoH, «tls://…» → DoT, иначе TCP.
    public static JsonObject DnsServer(string raw, string tag)
    {
        var v = raw.Trim();
        if (Uri.TryCreate(v, UriKind.Absolute, out var u) && u.Host.Length > 0 && u.Scheme is "https" or "tls" or "quic" or "tcp" or "udp")
        {
            var d = new JsonObject { ["type"] = u.Scheme, ["tag"] = tag, ["server"] = u.IdnHost };
            if (u.Port > 0) d["server_port"] = u.Port;
            if (u.Scheme == "https" && u.AbsolutePath.Length > 1) d["path"] = u.PathAndQuery;
            return d;
        }
        string[] dohIPs = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "94.140.14.14"];
        if (dohIPs.Contains(v)) return new JsonObject { ["type"] = "https", ["tag"] = tag, ["server"] = v };
        return new JsonObject { ["type"] = "tcp", ["tag"] = tag, ["server"] = v.Length == 0 ? "1.1.1.1" : v };
    }

    public static List<string> Cleaned(IEnumerable<string> list) =>
        list.Select(x => x.Trim()).Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();

    /// «example.com» → домен и все поддомены; «geosite:», «regexp:», «full:», «keyword:» — как есть.
    static string DomainRule(string s) => s.Contains(':') ? s : "domain:" + s.ToLowerInvariant();

    /// Проверка и нормализация CIDR: «1.2.3.4» → «1.2.3.4/32».
    public static string? Cidr(string s)
    {
        var parts = s.Split('/');
        if (parts.Length > 2 || s.StartsWith('/') || s.EndsWith('/')) return null;
        if (!IPAddress.TryParse(parts[0], out var ip) || parts[0].Count(c => c == '.') is not (0 or 3)) return null;
        var v4 = ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork;
        if (v4 && parts[0].Count(c => c == '.') != 3) return null;
        if (parts.Length == 2) return int.TryParse(parts[1], out var n) && n >= 0 && n <= (v4 ? 32 : 128) ? s : null;
        return parts[0] + (v4 ? "/32" : "/128");
    }
}
