using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Tutun.Core;

// Модели повторяют TutunShared (мак) поле в поле: JSON совместим в обе стороны.

public enum ConnectionMode { Tun, Proxy }
public enum RoutingMode { Rule, Global, Direct }
public enum AppsMode { Exclude, Include }
public enum PingType { Tcp, Url }
public enum CountryPick { Fastest, LastUsed, First, Random }
public enum ServerSort { Ping, Name, None }
public enum Engine { Xray, Singbox }

public sealed class Server
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Proto { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; }
    public string Transport { get; set; } = "tcp";
    /// Outbound без тега: для xray (Engine=Xray) или sing-box (Engine=Singbox).
    public string OutboundJSON { get; set; } = "{}";
    public Engine Engine { get; set; } = Engine.Xray;
    public Guid? SubscriptionID { get; set; }
    public bool Favorite { get; set; }
    /// Исходная ссылка — для копирования и редактирования.
    public string? RawLink { get; set; }

    [JsonIgnore] public JsonObject Outbound => Json.ParseObject(OutboundJSON) ?? new JsonObject();

    /// Флаг страны из начала имени (🇩🇪 …).
    [JsonIgnore]
    public string? Flag
    {
        get
        {
            var runes = Name.TrimStart(' ').EnumerateRunes().Take(2).ToArray();
            if (runes.Length != 2 || !runes.All(r => r.Value is >= 0x1F1E6 and <= 0x1F1FF)) return null;
            return runes[0].ToString() + runes[1].ToString();
        }
    }

    /// Код страны («SE») из флага.
    [JsonIgnore]
    public string? CountryCode
    {
        get
        {
            var f = Flag;
            if (f == null) return null;
            var sb = new StringBuilder();
            foreach (var r in f.EnumerateRunes()) sb.Append((char)(r.Value - 0x1F1E6 + 'A'));
            return sb.ToString();
        }
    }

    /// Имя без флага в начале.
    public string CleanName(string display)
    {
        if (Flag == null) return display;
        var sb = new StringBuilder();
        bool skipping = true;
        foreach (var r in display.EnumerateRunes())
        {
            if (skipping && (r.Value is >= 0x1F1E6 and <= 0x1F1FF || r.Value == ' ' || r.Value == 0xFE0F)) continue;
            skipping = false; sb.Append(r.ToString());
        }
        return sb.ToString().Trim();
    }

    public Server Copy() => (Server)MemberwiseClone();
}

/// Профиль маршрутов (совместим с форматом happ://routing/add/…).
public sealed class RoutingProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<string> DirectSites { get; set; } = new();
    public List<string> DirectIPs { get; set; } = new();
    public List<string> ProxySites { get; set; } = new();
    public List<string> ProxyIPs { get; set; } = new();
    public List<string> BlockSites { get; set; } = new();
    public List<string> BlockIPs { get; set; } = new();
    public string? DomainStrategy { get; set; }
    public string? RemoteDNS { get; set; }
    public string? DirectDNS { get; set; }
    public string? GeoipURL { get; set; }
    public string? GeositeURL { get; set; }
    public Dictionary<string,string>? DnsHosts { get; set; }
    public string? RouteOrder { get; set; }
    public bool GlobalProxy { get; set; } = true;
    public Guid? FromSubscription { get; set; }
}

public sealed class Subscription
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public DateTimeOffset? LastUpdate { get; set; }
    public string? LastError { get; set; }
    public long Upload { get; set; }
    public long Download { get; set; }
    public long Total { get; set; }
    public DateTimeOffset? Expire { get; set; }
    public string? Announce { get; set; }
    public string? SupportURL { get; set; }
    public string? WebPageURL { get; set; }
    public int UpdateIntervalHours { get; set; } = 12;
    public bool Enabled { get; set; } = true;
    public bool Collapsed { get; set; }

    public string ListMode { get; set; } = "countries";
    public string ListSort { get; set; } = "name";
    public Subscription Copy() => (Subscription)MemberwiseClone();
}

public sealed class AppSettings
{
    // Подключение
    public ConnectionMode Mode { get; set; } = ConnectionMode.Tun;
    public bool KillSwitch { get; set; } = true;
    public bool AutoSelect { get; set; } = true;
    public string? SelectedServerID { get; set; }
    public string? SelectedCountry { get; set; }
    public List<string> FavoriteCountries { get; set; } = new();
    public CountryPick CountryPick { get; set; } = CountryPick.Fastest;
    public bool CountryPreferFavorites { get; set; } = true;
    public Dictionary<string, string> LastServerByCountry { get; set; } = new();
    public bool Failover { get; set; } = true;
    public string? ChainServerID { get; set; }
    public bool ConnectOnLaunch { get; set; }
    public bool LaunchAtLogin { get; set; }
    public bool ShowInDock { get; set; } = true;

    // Маршруты
    public RoutingMode RoutingMode { get; set; } = RoutingMode.Rule;
    /// Сайты страны — напрямую (имя поля историческое, как на маке). Какой страны — DirectCountry.
    public bool RussiaDirect { get; set; } = true;
    /// Код страны для «сайты страны — напрямую»: ru, cn, ir, mm, tr, ae (HomeRegions).
    public string DirectCountry { get; set; } = "ru";
    public bool BlockAds { get; set; }
    public List<string> DirectDomains { get; set; } = new();
    public List<string> ProxyDomains { get; set; } = new();
    public List<string> BlockDomains { get; set; } = new();
    public List<string> DirectIPs { get; set; } = new();
    public List<string> ProxyIPs { get; set; } = new();
    public List<string> BlockIPs { get; set; } = new();
    public List<string> ExcludedRoutes { get; set; } = new();
    public string DomainStrategy { get; set; } = "IPIfNonMatch";
    public Guid? ActiveProfileID { get; set; }
    public AppsMode AppsMode { get; set; } = AppsMode.Exclude;
    public List<string> DirectApps { get; set; } = new();
    public List<string> IncludeApps { get; set; } = new();

    // Туннель
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
    public string LogLevel { get; set; } = "warning";

    // Локальная сеть
    public bool AllowLAN { get; set; }
    public int LanSocksPort { get; set; } = 10810;
    public int LanHttpPort { get; set; } = 10811;
    public string LanUser { get; set; } = "";
    public string LanPassword { get; set; } = "";

    // Проверка серверов
    public PingType PingType { get; set; } = PingType.Url;
    public string TestURL { get; set; } = "https://www.gstatic.com/generate_204";
    public bool TestMethodHead { get; set; }
    public int TestTimeout { get; set; } = 5;
    public bool PingOnLaunch { get; set; } = true;
    public bool PingAfterUpdate { get; set; } = true;
    public ServerSort Sort { get; set; } = ServerSort.Ping;

    // Подписки
    public string Hwid { get; set; } = "";
    /// По умолчанию выключено (как на маке с 08.11); сохранённое значение у прежних установок не меняется.
    public bool SendHWID { get; set; }
    public string UserAgent { get; set; } = "";
    /// Разрешить подписки по http:// (по умолчанию только https). ID устройства по http не отправляется никогда.
    public bool AllowHttpSubscriptions { get; set; }
    public int SubTimeout { get; set; } = 30;
    public bool IgnoreDuplicates { get; set; } = true;
    public bool UpdateSubsOnLaunch { get; set; } = true;
    public int ExpiryWarnDays { get; set; } = 3;

    // Автоматизация
    public bool Notifications { get; set; } = true;
    public bool Hotkey { get; set; } = true;
    public bool OnDemand { get; set; }
    public List<string> TrustedSSIDs { get; set; } = new();
    public bool GeoAutoUpdate { get; set; }
    public string GeoipURL { get; set; } = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat";
    public string GeositeURL { get; set; } = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat";
    public DateTimeOffset? GeoLastUpdate { get; set; }

    public Dictionary<string, string> ServerRenames { get; set; } = new();

    // Автопереключение
    public int ProbeIntervalSec { get; set; } = 30;
    public int HealthFailLimit { get; set; } = 3;

    /// Глубокая копия через JSON — черновик и принятые настройки никогда не делят списки.
    public AppSettings Copy() => Json.Deserialize<AppSettings>(Json.Serialize(this))!;

    public bool SameAs(AppSettings other) => Json.Serialize(this) == Json.Serialize(other);
}
