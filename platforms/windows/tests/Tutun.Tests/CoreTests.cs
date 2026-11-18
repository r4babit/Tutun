using System.Diagnostics;
using System.Text;
using Tutun.Core;
using Xunit;

namespace Tutun.Tests;

public class CoreTests
{
    const string Uuid = "b831381d-6324-4d53-ad4f-8cda48b30811";
    const string WgKey = "cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ=";
    static string B64(string s) => Convert.ToBase64String(Encoding.UTF8.GetBytes(s));

    // Те же образцы, что в мак-тестах.
    static string[] Samples
    {
        get
        {
            var vmessJSON = $"{{\"v\":\"2\",\"ps\":\"VM WS\",\"add\":\"vm.example.com\",\"port\":\"443\",\"id\":\"{Uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"cdn.example.com\",\"path\":\"/ws\",\"tls\":\"tls\",\"sni\":\"cdn.example.com\"}}";
            var wg = Uri.EscapeDataString(WgKey);
            return
            [
                $"vless://{Uuid}@1.2.3.4:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBLjF4hs&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F",
                $"vless://{Uuid}@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fxh&mode=auto&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#XHTTP",
                $"vless://{Uuid}@g.example.com:443?type=grpc&serviceName=svc&security=tls&sni=g.example.com#gRPC",
                "trojan://pass%40word@t.example.com:443?sni=t.example.com&type=ws&path=%2Ftr#Trojan",
                "vmess://" + B64(vmessJSON),
                "ss://" + B64("chacha20-ietf-poly1305:secret") + "@5.6.7.8:8388#SS",
                "ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2BOTw%3D%3D@9.9.9.9:443#SS2022",
                "hysteria2://authpw@h.example.com:8443?sni=h.example.com#HY2",
                "hysteria2://authpw@o.example.com:443?sni=o.example.com&obfs=salamander&obfs-password=secret#HY2-obfs",
                $"tuic://{Uuid}:pw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com#TUIC",
                $"wireguard://{wg}@wg.example.com:51820?publickey={wg}&address=10.7.0.2/32&reserved=1,2,3#WG",
                "socks://" + B64("user:pass") + "@s.example.com:1080#SOCKS",
            ];
        }
    }

    static List<Server> ParsedSamples() => Samples.Select(s => LinkParser.Parse(s)).ToList();

    [Fact]
    public void HappProfileKeepsDnsAndRulePriorityAcrossPlatforms()
    {
        var profile = RoutingProfiles.ParseJSON("""{"DirectSites":["test.example"],"ProxySites":["test.example"],"RemoteDNSType":"DoH","RemoteDNSDomain":"https://dns.example/dns-query","RouteOrder":"direct-block-proxy","DnsHosts":{"TEST.example":"192.0.2.4","bad key":"invalid"}}""")!;
        var imported = RoutingProfiles.ParseLink(RoutingProfiles.Link(profile))!;
        Assert.Equal("https://dns.example/dns-query", imported.RemoteDNS);
        Assert.Equal("192.0.2.4", Assert.Single(imported.DnsHosts!).Value);
        var input = new ConnectionInput { Servers = [ParsedSamples()[0]], Profile = imported };
        var xray = Json.ParseObject(ConfigBuilder.Xray(input))!;
        Assert.Equal("192.0.2.4", xray["dns"]!["hosts"]!["test.example"]!.ToString());
        var rules = xray.Obj("routing").Arr("rules")!;
        Assert.Equal("direct", rules.First(rule => rule.Arr("domain")?.Any(d => d!.ToString().Contains("test.example")) == true).Str("outboundTag"));
        var tun = Json.ParseObject(ConfigBuilder.SingBox(input))!;
        Assert.Equal("pinned", tun.Obj("dns").Arr("rules")![0].Str("server"));
    }

    [Fact]
    public void ParseAll()
    {
        var servers = ParsedSamples();
        Assert.Equal(["vless", "vless", "vless", "trojan", "vmess", "shadowsocks", "shadowsocks", "hysteria2", "hysteria2", "tuic", "wireguard", "socks"],
                     servers.Select(s => s.Proto));
        Assert.Equal("Германия", servers[0].Name);
        Assert.Equal(Engine.Xray, servers[7].Engine);
        Assert.Equal(Engine.Singbox, servers[8].Engine);
        Assert.Equal(Engine.Singbox, servers[9].Engine);
        Assert.NotNull(servers[0].RawLink);
        var trojanPw = (servers[3].Outbound.Obj("settings").Arr("servers")![0] as System.Text.Json.Nodes.JsonObject).Str("password");
        Assert.Equal("pass@word", trojanPw);
        Assert.Equal(servers.Count, servers.Select(s => s.Id).Distinct().Count());
        Assert.Equal("user", ((servers[11].Outbound.Obj("settings").Arr("servers")![0] as System.Text.Json.Nodes.JsonObject).Arr("users")![0] as System.Text.Json.Nodes.JsonObject).Str("user"));
    }

    [Fact]
    public void StableIDMatchesSwift()
    {
        // SHA256("abc") = ba7816bf8f01cfea…; первые 8 байт в hex — как LinkParser.stableID на маке.
        Assert.Equal("ba7816bf8f01cfea", LinkParser.StableID("abc"));
    }

    [Fact]
    public void FlagAndCountry()
    {
        var s = new Server { Name = "🇩🇪 Frankfurt 1" };
        Assert.Equal("DE", s.CountryCode);
        Assert.Equal("Frankfurt 1", s.CleanName(s.Name));
        Assert.Equal("Германия", Countries.Name("DE"));
        Assert.Null(new Server { Name = "Без флага" }.CountryCode);
    }

    [Fact]
    public void BatchWithProfiles()
    {
        var profileJSON = "{\"Name\":\"RU\",\"DirectSites\":[\"geosite:category-ru\"],\"ProxySites\":[\"youtube.com\"],\"BlockSites\":[\"geosite:category-ads-all\"],\"DomainStrategy\":\"IPIfNonMatch\",\"GlobalProxy\":\"true\"}";
        var lines = Samples.Concat(["happ://routing/add/" + B64(profileJSON), "happ://crypt4/abcdef", "awg://x@y:1"]);
        var b = LinkParser.ParseBatch(B64(string.Join("\n", lines)), null);
        Assert.Equal(Samples.Length, b.Servers.Count);
        Assert.Single(b.Profiles);
        Assert.Equal(["youtube.com"], b.Profiles[0].ProxySites);
        Assert.Equal(2, b.Errors.Count);
        var back = RoutingProfiles.ParseLink(RoutingProfiles.Link(b.Profiles[0]));
        Assert.Equal(["geosite:category-ads-all"], back!.BlockSites);
    }

    [Fact]
    public void WireGuardConf()
    {
        var conf = $"[Interface]\nPrivateKey = {WgKey}\nAddress = 10.8.0.2/32\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = {WgKey}\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n";
        Assert.Equal("wireguard", LinkParser.ParseBatch(conf, null).Servers.First().Proto);
        var awg = conf.Replace("DNS", "Jc = 4\nDNS");
        Assert.Empty(LinkParser.ParseBatch(awg, null).Servers);
    }

    [Fact]
    public void SubscriptionBodyJSON()
    {
        var cfg = $"[{{\"remarks\":\"JSON сервер\",\"outbounds\":[{{\"tag\":\"proxy\",\"protocol\":\"vless\",\"settings\":{{\"vnext\":[{{\"address\":\"j.example.com\",\"port\":443,\"users\":[{{\"id\":\"{Uuid}\",\"encryption\":\"none\"}}]}}]}},\"streamSettings\":{{\"network\":\"tcp\",\"security\":\"tls\",\"sockopt\":{{\"dialerProxy\":\"frag\"}}}}}},{{\"tag\":\"direct\",\"protocol\":\"freedom\"}}]}}]";
        var r = LinkParser.ParseBatch(cfg, null);
        Assert.Single(r.Servers);
        Assert.Equal("JSON сервер", r.Servers[0].Name);
        Assert.DoesNotContain("dialerProxy", r.Servers[0].OutboundJSON);
        Assert.Equal("j.example.com", r.Servers[0].Host);
    }

    [Fact]
    public void PlainVlessRejected()
    {
        Assert.NotNull(LinkParser.RejectReason(LinkParser.Parse($"vless://{Uuid}@de.example.com:80?type=ws&security=none&path=%2F#Plain")));
        Assert.Null(LinkParser.RejectReason(LinkParser.Parse($"vless://{Uuid}@192.168.1.5:80?type=tcp&security=none#LAN")));
    }

    [Fact]
    public void MalformedCIDRDoesNotCrash()
    {
        foreach (var bad in new[] { "", "/", "1.2.3.4/", "/24", "1.2.3.4/33", "1.2.3/24", "::1/129", "мусор", "1.2.3.4/8/9" })
            Assert.Null(ConfigBuilder.Cidr(bad));
        Assert.Equal("1.2.3.4/32", ConfigBuilder.Cidr("1.2.3.4"));
        Assert.Equal("::1/128", ConfigBuilder.Cidr("::1"));
        Assert.Equal("10.0.0.0/8", ConfigBuilder.Cidr("10.0.0.0/8"));
    }

    [Fact]
    public void SelectingServerDoesNotAcceptDraftSettings()
    {
        var accepted = new AppSettings();
        var oldDraft = accepted.Copy();
        oldDraft.Mode = ConnectionMode.Proxy; oldDraft.OnDemand = true;
        var newDraft = oldDraft.Copy();
        newDraft.SelectedServerID = "new-server"; newDraft.AutoSelect = false;
        var runtime = SettingsPolicy.MergingRuntimeChanges(oldDraft, newDraft, accepted);
        Assert.Equal("new-server", runtime.SelectedServerID);
        Assert.False(runtime.AutoSelect);
        Assert.Equal(accepted.Mode, runtime.Mode);
        Assert.Equal(accepted.OnDemand, runtime.OnDemand);
        Assert.False(newDraft.SameAs(runtime));
    }

    [Fact]
    public void ServiceRejectsUnsafeConnectionPlans()
    {
        ConnectionInput Valid() => new() { Servers = ParsedSamples(), Settings = new AppSettings() };
        ConnectionValidation.Validate(Valid());
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(new ConnectionInput()));
        var x = Valid(); x.Settings.TestURL = "file:///C:/Windows/win.ini";
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x = Valid(); x.Settings.AllowLAN = true;
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x.Settings.LanUser = "fixture"; x.Settings.LanPassword = "fixture-password";
        ConnectionValidation.Validate(x);
        x.Settings.LanSocksPort = Paths.ApiPort;
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x = Valid(); x.Servers[0].OutboundJSON = "{\"protocol\":\"vless\",\"streamSettings\":{\"tlsSettings\":{\"certificates\":[{\"keyFile\":\"C:\\\\secret\"}]}}}";
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x = Valid(); x.Servers[0].OutboundJSON = "{\"protocol\":\"freedom\"}";
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x = Valid(); x.Servers[0].OutboundJSON = "{\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"C:\\\\pipe\"}]}}";
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
        x = Valid(); x.Settings.DirectDomains = ["ext:../../private:example"];
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(x));
    }

    [Fact]
    public void ConnectionPlanSurvivesIPCEncoding()
    {
        var req = new DaemonRequest { Cmd = DaemonCommand.Start, Connection = new ConnectionInput { Servers = ParsedSamples(), Settings = new AppSettings() } };
        var text = Json.Serialize(req);
        Assert.Contains("\"cmd\":\"start\"", text);
        var back = Json.Deserialize<DaemonRequest>(text)!;
        Assert.Equal(Samples.Length, back.Connection!.Servers.Count);
        Assert.True(back.Connection.Settings.SameAs(new AppSettings()));
        ConnectionValidation.Validate(back.Connection);
    }

    [Fact]
    public void ReadsMacStyleJson()
    {
        // Фрагмент app.json мака: UUID в верхнем регистре, даты ISO 8601, незнакомые поля.
        var mac = "{\"mode\":\"proxy\",\"routingMode\":\"global\",\"selectedCountry\":\"SE\",\"unknownField\":1,\"geoLastUpdate\":\"2026-11-01T10:00:00Z\",\"activeProfileID\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\"}";
        var s = Json.Deserialize<AppSettings>(mac)!;
        Assert.Equal(ConnectionMode.Proxy, s.Mode);
        Assert.Equal(RoutingMode.Global, s.RoutingMode);
        Assert.Equal("SE", s.SelectedCountry);
        Assert.NotNull(s.GeoLastUpdate);
        Assert.NotNull(s.ActiveProfileID);
        Assert.True(s.KillSwitch);   // отсутствующее поле — значение по умолчанию
    }

    [Fact]
    public void DemoProfileFromShared()
    {
        var path = Path.Combine(RepoRoot, "shared", "examples", "demo-profile.tutun.json");
        var p = ConfigurationProfile.Decode(File.ReadAllBytes(path));
        Assert.Single(p.Servers);
        Assert.Equal("socks", p.Servers[0].Proto);
        var again = ConfigurationProfile.Decode(Encoding.UTF8.GetBytes(p.Encode()));
        Assert.Equal(p.Servers[0].OutboundJSON, again.Servers[0].OutboundJSON);
        var bad = File.ReadAllText(path).Replace("\"schemaVersion\" : 1", "\"schemaVersion\" : 2");
        Assert.Throws<ValidationException>(() => ConfigurationProfile.Decode(Encoding.UTF8.GetBytes(bad)));
    }

    [Fact]
    public void PortablePreferencesKeepDeviceFields()
    {
        var local = new AppSettings { Hwid = "device", LaunchAtLogin = true, DirectApps = ["Telegram.exe"] };
        var common = new ConnectionPreferences { RemoteDNS = "9.9.9.9", BlockAds = true };
        common.ApplyTo(local);
        Assert.Equal("device", local.Hwid);
        Assert.True(local.LaunchAtLogin);
        Assert.Equal(["Telegram.exe"], local.DirectApps);
        Assert.Equal("9.9.9.9", local.RemoteDNS);
        Assert.True(local.BlockAds);
    }

    // Настоящие ядра Windows

    static string RepoRoot
    {
        get
        {
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d != null && !Directory.Exists(Path.Combine(d.FullName, "vendor"))) d = d.Parent;
            return d?.FullName ?? throw new InvalidOperationException("нет vendor");
        }
    }

    static string Bin => Path.Combine(RepoRoot, "vendor", "bin");

    static (int, string) Run(string exe, params string[] args)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["XRAY_LOCATION_ASSET"] = Bin;
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
        p.WaitForExit();
        return (p.ExitCode, o.Result + e.Result);
    }

    static void CheckWithCores(BuiltConfig built)
    {
        var tmp = Directory.CreateTempSubdirectory("tutun-test-");
        try
        {
            var x = Path.Combine(tmp.FullName, "x.json");
            File.WriteAllText(x, built.Xray);
            var (c1, o1) = Run(Path.Combine(Bin, "xray.exe"), "run", "-test", "-c", x);
            Assert.True(c1 == 0, "xray: " + o1);
            foreach (var (name, cfg) in new[] { ("s", built.SingBox), ("h", built.Helper) })
            {
                if (cfg == null) continue;
                var p = Path.Combine(tmp.FullName, name + ".json");
                File.WriteAllText(p, cfg);
                var (c, o) = Run(Path.Combine(Bin, "sing-box.exe"), "check", "-c", p);
                Assert.True(c == 0, name + ": " + o);
            }
        }
        finally { tmp.Delete(true); }
    }

    [Fact]
    public void ConfigsAcceptedByCores()
    {
        var servers = ParsedSamples();
        var s = new AppSettings
        {
            DirectDomains = ["example.org", "geosite:apple"], ProxyDomains = ["youtube.com"], BlockDomains = ["ads.example.com"],
            DirectIPs = ["8.8.8.8/32"], BlockIPs = ["1.2.3.0/24"], ExcludedRoutes = ["192.0.2.10", "198.51.100.0/24", "мусор"],
            DirectApps = ["Telegram"], BlockAds = true, Fragment = true, Noises = true, Mux = true,
            AllowLAN = true, LanUser = "u", LanPassword = "p", Ipv6 = true, RemoteDNS = "https://dns.google/dns-query",
        };
        var profile = RoutingProfiles.ParseJSON("{\"Name\":\"P\",\"DirectSites\":[\"geosite:category-gov-ru\"],\"ProxyIp\":[\"91.108.4.0/22\"],\"GlobalProxy\":\"true\"}");

        // Автовыбор по всем серверам
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = servers, Settings = s, Profile = profile, ClashSecret = "x" }));
        // Один сервер, цепочка через другой, режим прокси
        var s2 = s.Copy(); s2.Mode = ConnectionMode.Proxy; s2.Fragment = false; s2.Noises = false;
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = [servers[1]], Settings = s2, Chain = servers[0] }));
        // Ручной выбор с подстраховкой, только выбранные приложения, всё напрямую
        var s3 = s.Copy(); s3.AppsMode = AppsMode.Include; s3.IncludeApps = ["chrome.exe"]; s3.RoutingMode = RoutingMode.Direct;
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = [servers[0], servers[2]], Settings = s3, FailoverOnly = true }));
        // Глобальный режим, только sing-box серверы
        var s4 = new AppSettings { RoutingMode = RoutingMode.Global };
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = [servers[8], servers[9]], Settings = s4 }));
        // Демо-профиль из shared
        var demo = ConfigurationProfile.Decode(File.ReadAllBytes(Path.Combine(RepoRoot, "shared", "examples", "demo-profile.tutun.json")));
        var ds = new AppSettings(); demo.Preferences.ApplyTo(ds);
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = demo.Servers, Settings = ds }));
    }

    [Fact]
    public void Hy2PortHoppingAcceptedBySingBox()
    {
        var s = LinkParser.Parse("hysteria2://pw@h.example.com:443?sni=h.example.com&mport=443,20000-30000#HOP");
        Assert.Equal(Engine.Singbox, s.Engine);
        Assert.Equal(["443:443", "20000:30000"], s.Outbound.Arr("server_ports")!.Select(x => x!.ToString()));
        Assert.Throws<LinkException>(() => LinkParser.Parse("hysteria2://pw@h.example.com:443?mport=70000#BAD"));
        CheckWithCores(ConfigBuilder.Build(new ConnectionInput { Servers = [s], Settings = new AppSettings() }));
    }

    [Fact]
    public async Task SubscriptionRequiresHttps()
    {
        var ex = await Assert.ThrowsAsync<SubscriptionException>(() =>
            SubscriptionFetcher.FetchAsync(new Subscription { Url = "http://example.com/sub" }, new FetchOptions("x", true, "", TimeSpan.FromSeconds(5))));
        Assert.Contains("https", ex.Message);
        // С разрешением http проверка схемы пропускает ссылку (дальше — обычная сетевая ошибка, не отказ по схеме).
        var ex2 = await Assert.ThrowsAsync<SubscriptionException>(() =>
            SubscriptionFetcher.FetchAsync(new Subscription { Url = "http://127.0.0.1:9/sub" }, new FetchOptions("x", true, "", TimeSpan.FromSeconds(3), AllowHttp: true)));
        Assert.DoesNotContain("не защищена", ex2.Message);
        Assert.False(new AppSettings().AllowHttpSubscriptions);
        Assert.Contains("\"allowHttpSubscriptions\":false", Json.Serialize(new AppSettings()));
    }

    [Fact]
    public void AllHomeRegionsAcceptedByXray()
    {
        var servers = ParsedSamples();
        foreach (var r in HomeRegions.All)
        {
            var s = new AppSettings { DirectCountry = r.Code, RussiaDirect = true };
            var built = ConfigBuilder.Build(new ConnectionInput { Servers = [servers[0]], Settings = s });
            Assert.Contains(r.Ips[0], built.Xray);
            CheckWithCores(built);
            ConnectionValidation.Validate(new ConnectionInput { Servers = [servers[0]], Settings = s });
        }
        Assert.Throws<ValidationException>(() => ConnectionValidation.Validate(new ConnectionInput { Servers = [servers[0]], Settings = new AppSettings { DirectCountry = "xx" } }));
        // Старый app.json без поля — Россия, как раньше.
        Assert.Equal("ru", Json.Deserialize<AppSettings>("{\"russiaDirect\":true}")!.DirectCountry);
    }

    [Fact]
    public void MissingGeoipCodesAreSkipped()
    {
        var codes = GeoData.ReadGeoipCodes(Path.Combine(Bin, "geoip.dat"));
        Assert.NotNull(codes);
        Assert.Contains("RU", codes!);
        // Урезанная база, как на маке: TR нет — правило по IP не добавляется, конфиг всё равно собирается.
        var old = ConfigBuilder.GeoipCodes;
        try
        {
            ConfigBuilder.GeoipCodes = ["RU", "CN", "IR", "PRIVATE"];
            var x = ConfigBuilder.Xray(new ConnectionInput { Servers = [ParsedSamples()[0]], Settings = new AppSettings { DirectCountry = "tr" } });
            Assert.DoesNotContain("geoip:tr", x);
            Assert.Contains(".tr$", x);
        }
        finally { ConfigBuilder.GeoipCodes = old; }
    }

    [Fact]
    public void ProfileWithMissingGeoCodesStillRuns()
    {
        var old = (ConfigBuilder.GeoipCodes, ConfigBuilder.GeositeCodes);
        try
        {
            ConfigBuilder.GeoipCodes = GeoData.ReadGeoipCodes(Path.Combine(Bin, "geoip.dat"));
            ConfigBuilder.GeositeCodes = GeoData.ReadGeoipCodes(Path.Combine(Bin, "geosite.dat"));
            Assert.Contains("CATEGORY-RU", ConfigBuilder.GeositeCodes!);
            // Профиль провайдера под другую базу: blacklist-ru / in-ru / несуществующий geosite.
            var profile = RoutingProfiles.ParseJSON("{\"Name\":\"P\",\"DirectIp\":[\"geoip:in-ru\",\"10.0.0.0/8\"],\"BlockIp\":[\"geoip:blacklist-ru\"],\"ProxySites\":[\"geosite:no-such-list\",\"youtube.com\"],\"BlockSites\":[\"geosite:category-ads-all@ads\"]}");
            lock (ConfigBuilder.Skipped) ConfigBuilder.Skipped.Clear();
            var built = ConfigBuilder.Build(new ConnectionInput { Servers = [ParsedSamples()[0]], Settings = new AppSettings(), Profile = profile });
            Assert.DoesNotContain("blacklist-ru", built.Xray);
            Assert.DoesNotContain("no-such-list", built.Xray);
            Assert.Contains("youtube.com", built.Xray);
            Assert.Contains("geoip:in-ru", ConfigBuilder.Skipped);
            CheckWithCores(built);
        }
        finally { (ConfigBuilder.GeoipCodes, ConfigBuilder.GeositeCodes) = old; }
    }
}
