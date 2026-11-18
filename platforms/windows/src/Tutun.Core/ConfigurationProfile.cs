namespace Tutun.Core;

/// Только общие сетевые настройки (tutun.profile v1). Права, автозапуск, HWID и правила приложений сюда не входят.
public sealed class ConnectionPreferences
{
    public ConnectionMode Mode { get; set; } = ConnectionMode.Tun;
    public RoutingMode RoutingMode { get; set; } = RoutingMode.Rule;
    public bool RussiaDirect { get; set; } = true;
    public string DirectCountry { get; set; } = "ru";
    public bool BlockAds { get; set; }
    public bool Failover { get; set; } = true;
    public string? ChainServerID { get; set; }
    public Guid? ActiveProfileID { get; set; }
    public CountryPick CountryPick { get; set; } = CountryPick.Fastest;
    public bool CountryPreferFavorites { get; set; } = true;
    public List<string> DirectDomains { get; set; } = new();
    public List<string> ProxyDomains { get; set; } = new();
    public List<string> BlockDomains { get; set; } = new();
    public List<string> DirectIPs { get; set; } = new();
    public List<string> ProxyIPs { get; set; } = new();
    public List<string> BlockIPs { get; set; } = new();
    public List<string> ExcludedRoutes { get; set; } = new();
    public string DomainStrategy { get; set; } = "IPIfNonMatch";
    public bool Sniffing { get; set; } = true;
    public bool Ipv6 { get; set; }
    public string RemoteDNS { get; set; } = "1.1.1.1";
    public string DirectDNS { get; set; } = "77.88.8.8";
    public bool Fragment { get; set; }
    public string FragmentPackets { get; set; } = "tlshello";
    public string FragmentLength { get; set; } = "100-200";
    public string FragmentInterval { get; set; } = "10-20";
    public bool Noises { get; set; }
    public bool Mux { get; set; }
    public int MuxConcurrency { get; set; } = 8;
    public string TestURL { get; set; } = "https://www.gstatic.com/generate_204";
    public int TestTimeout { get; set; } = 5;
    public int ProbeIntervalSec { get; set; } = 30;
    public int HealthFailLimit { get; set; } = 3;

    public void Validate()
    {
        if (ProbeIntervalSec is < 10 or > 300 || HealthFailLimit is < 1 or > 10 || TestTimeout is < 2 or > 30
            || MuxConcurrency is < 1 or > 128 || !ConnectionValidation.HttpURL(TestURL))
            throw new ValidationException("Некорректные общие сетевые настройки");
    }

    /// Перенести общие настройки в настройки устройства, не трогая локальные поля (HWID, автозапуск, приложения).
    public void ApplyTo(AppSettings s)
    {
        s.Mode = Mode; s.RoutingMode = RoutingMode; s.RussiaDirect = RussiaDirect; s.DirectCountry = DirectCountry; s.BlockAds = BlockAds; s.Failover = Failover;
        s.ChainServerID = ChainServerID; s.ActiveProfileID = ActiveProfileID; s.CountryPick = CountryPick; s.CountryPreferFavorites = CountryPreferFavorites;
        s.DirectDomains = new(DirectDomains); s.ProxyDomains = new(ProxyDomains); s.BlockDomains = new(BlockDomains);
        s.DirectIPs = new(DirectIPs); s.ProxyIPs = new(ProxyIPs); s.BlockIPs = new(BlockIPs); s.ExcludedRoutes = new(ExcludedRoutes);
        s.DomainStrategy = DomainStrategy; s.Sniffing = Sniffing; s.Ipv6 = Ipv6; s.RemoteDNS = RemoteDNS; s.DirectDNS = DirectDNS;
        s.Fragment = Fragment; s.FragmentPackets = FragmentPackets; s.FragmentLength = FragmentLength; s.FragmentInterval = FragmentInterval;
        s.Noises = Noises; s.Mux = Mux; s.MuxConcurrency = MuxConcurrency; s.TestURL = TestURL; s.TestTimeout = TestTimeout;
        s.ProbeIntervalSec = ProbeIntervalSec; s.HealthFailLimit = HealthFailLimit;
    }

    public static ConnectionPreferences From(AppSettings s) => new()
    {
        Mode = s.Mode, RoutingMode = s.RoutingMode, RussiaDirect = s.RussiaDirect, DirectCountry = s.DirectCountry, BlockAds = s.BlockAds, Failover = s.Failover,
        ChainServerID = s.ChainServerID, ActiveProfileID = s.ActiveProfileID, CountryPick = s.CountryPick, CountryPreferFavorites = s.CountryPreferFavorites,
        DirectDomains = new(s.DirectDomains), ProxyDomains = new(s.ProxyDomains), BlockDomains = new(s.BlockDomains),
        DirectIPs = new(s.DirectIPs), ProxyIPs = new(s.ProxyIPs), BlockIPs = new(s.BlockIPs), ExcludedRoutes = new(s.ExcludedRoutes),
        DomainStrategy = s.DomainStrategy, Sniffing = s.Sniffing, Ipv6 = s.Ipv6, RemoteDNS = s.RemoteDNS, DirectDNS = s.DirectDNS,
        Fragment = s.Fragment, FragmentPackets = s.FragmentPackets, FragmentLength = s.FragmentLength, FragmentInterval = s.FragmentInterval,
        Noises = s.Noises, Mux = s.Mux, MuxConcurrency = s.MuxConcurrency, TestURL = s.TestURL, TestTimeout = s.TestTimeout,
        ProbeIntervalSec = s.ProbeIntervalSec, HealthFailLimit = s.HealthFailLimit,
    };
}

/// Общий контракт обмена данными для клиентов macOS, Windows и Android (tutun.profile v1).
public sealed class ConfigurationProfile
{
    public const int CurrentVersion = 1;
    public string Format { get; set; } = "tutun.profile";
    public int SchemaVersion { get; set; } = CurrentVersion;
    public List<Server> Servers { get; set; } = new();
    public List<Subscription> Subscriptions { get; set; } = new();
    public List<RoutingProfile> RoutingProfiles { get; set; } = new();
    public ConnectionPreferences Preferences { get; set; } = new();

    public static ConfigurationProfile Decode(byte[] data)
    {
        if (data.Length > 16 * 1024 * 1024) throw new ValidationException("Профиль больше 16 МБ");
        ConfigurationProfile? p;
        try { p = Json.Deserialize<ConfigurationProfile>(data); }
        catch (Exception e) { throw new ValidationException("Профиль не читается: " + e.Message); }
        if (p == null) throw new ValidationException("Пустой профиль");
        p.Validate();
        return p;
    }

    public string Encode() { Validate(); return Json.Serialize(this, pretty: true); }

    public void Validate()
    {
        if (Format != "tutun.profile" || SchemaVersion != CurrentVersion) throw new ValidationException("Неподдерживаемый формат или версия профиля");
        if (Servers.Count > 10_000 || Servers.Select(s => s.Id).Distinct().Count() != Servers.Count
            || Subscriptions.Select(s => s.Id).Distinct().Count() != Subscriptions.Count
            || RoutingProfiles.Select(s => s.Id).Distinct().Count() != RoutingProfiles.Count)
            throw new ValidationException("Слишком много серверов или повторяются идентификаторы");
        var subIDs = Subscriptions.Select(s => s.Id).ToHashSet();
        foreach (var s in Servers)
        {
            if (s.Id.Length == 0 || s.Host.Length == 0 || s.Port is < 1 or > 65535 || Json.ParseObject(s.OutboundJSON) == null
                || (s.SubscriptionID is { } sid && !subIDs.Contains(sid)))
                throw new ValidationException("Некорректный сервер или отсутствует связанная подписка");
        }
        foreach (var sub in Subscriptions)
            if (!ConnectionValidation.HttpURL(sub.Url) || sub.UpdateIntervalHours is < 1 or > 168) throw new ValidationException("Некорректная подписка");
        Preferences.Validate();
        if ((Preferences.ChainServerID is { } c && Servers.All(s => s.Id != c))
            || (Preferences.ActiveProfileID is { } a && RoutingProfiles.All(r => r.Id != a)))
            throw new ValidationException("Некорректные настройки или ссылки на отсутствующие элементы");
        if (RoutingProfiles.Any(r => r.FromSubscription is { } f && !subIDs.Contains(f)))
            throw new ValidationException("Отсутствует подписка профиля маршрутов");
    }
}
