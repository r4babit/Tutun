using System.Text;
using System.Text.Json.Nodes;

namespace Tutun.Core;

/// Профили маршрутов в формате Happ: happ://routing/add/&lt;base64 JSON&gt; (а также onadd) или сам JSON.
public static class RoutingProfiles
{
    static readonly string[] Prefixes = ["happ://routing/add/", "happ://routing/onadd/", "tutun://routing/add/", "tutun://routing/"];

    public static string[]? RouteGroups(string? order)
    {
        var parts = order?.ToLowerInvariant().Split('-');
        return parts?.Length == 3 && parts.ToHashSet().SetEquals(["block", "proxy", "direct"]) ? parts : null;
    }

    public static RoutingProfile? ParseLink(string link)
    {
        var l = link.Trim();
        foreach (var prefix in Prefixes)
        {
            if (!l.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            var payload = l[prefix.Length..];
            var text = LinkParser.Base64Decode(payload) ?? UrlParts.Decode(payload);
            return ParseJSON(text);
        }
        return null;
    }

    public static RoutingProfile? ParseJSON(string text)
    {
        if (Json.ParseObject(text) is not { } o) return null;
        JsonNode? Value(string key) => o[key] ?? o.FirstOrDefault(kv => kv.Key.Equals(key, StringComparison.OrdinalIgnoreCase)).Value;
        List<string> List(string k) => Value(k) switch
        {
            JsonArray a => a.Select(x => x?.ToString().Trim() ?? "").Where(x => x.Length > 0).ToList(),
            JsonValue v when v.TryGetValue<string>(out var s) => s.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList(),
            _ => new List<string>(),
        };
        string? Str(string k) => Value(k)?.ToString().Trim() is { Length: > 0 } s ? s : null;
        var p = new RoutingProfile
        {
            Name = Str("Name") ?? Str("name") ?? "Профиль",
            DirectSites = List("DirectSites"), DirectIPs = List("DirectIp"),
            ProxySites = List("ProxySites"), ProxyIPs = List("ProxyIp"),
            BlockSites = List("BlockSites"), BlockIPs = List("BlockIp"),
            DomainStrategy = Str("DomainStrategy"),
            RemoteDNS = Str("RemoteDnsIP") ?? Str("RemoteDns"),
            DirectDNS = Str("DomesticDnsIP") ?? Str("DomesticDns"),
            GeoipURL = Str("Geoipurl"), GeositeURL = Str("Geositeurl"),
        };
        if (string.Equals(Str("RemoteDNSType"), "doh", StringComparison.OrdinalIgnoreCase) &&
            Uri.TryCreate(Str("RemoteDNSDomain"), UriKind.Absolute, out var doh) && doh.Scheme == "https")
            p.RemoteDNS = doh.AbsoluteUri;
        if (RouteGroups(Str("RouteOrder")) is { } order) p.RouteOrder = string.Join("-", order);
        if (Value("DnsHosts") is JsonObject hosts)
        {
            foreach (var (name, value) in hosts)
            {
                var domain = name.Trim().ToLowerInvariant();
                if (Uri.CheckHostName(domain) != UriHostNameType.Dns || !System.Net.IPAddress.TryParse(value?.ToString(), out var ip)) continue;
                (p.DnsHosts ??= new())[domain] = ip.ToString();
            }
        }
        if (Value("GlobalProxy") is { } g) p.GlobalProxy = g.ToString().Trim('"').ToLowerInvariant() != "false";
        var hasRules = p.DirectSites.Count + p.DirectIPs.Count + p.ProxySites.Count + p.ProxyIPs.Count + p.BlockSites.Count + p.BlockIPs.Count > 0;
        return hasRules || p.GeoipURL != null ? p : null;
    }

    /// Ссылка для отправки профиля на другое устройство (Happ её тоже понимает).
    public static string Link(RoutingProfile p)
    {
        var o = new JsonObject
        {
            ["Name"] = p.Name, ["DirectSites"] = Json.StrArray(p.DirectSites), ["DirectIp"] = Json.StrArray(p.DirectIPs),
            ["ProxySites"] = Json.StrArray(p.ProxySites), ["ProxyIp"] = Json.StrArray(p.ProxyIPs),
            ["BlockSites"] = Json.StrArray(p.BlockSites), ["BlockIp"] = Json.StrArray(p.BlockIPs),
            ["GlobalProxy"] = p.GlobalProxy ? "true" : "false",
        };
        if (p.RouteOrder != null) o["RouteOrder"] = p.RouteOrder;
        if (p.DnsHosts is { Count: > 0 }) o["DnsHosts"] = System.Text.Json.JsonSerializer.SerializeToNode(p.DnsHosts);
        if (p.DomainStrategy != null) o["DomainStrategy"] = p.DomainStrategy;
        if (p.RemoteDNS != null) o["RemoteDns"] = p.RemoteDNS;
        if (p.DirectDNS != null) o["DomesticDns"] = p.DirectDNS;
        if (p.GeoipURL != null) o["Geoipurl"] = p.GeoipURL;
        if (p.GeositeURL != null) o["Geositeurl"] = p.GeositeURL;
        return "happ://routing/add/" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Json.ToJSON(o)));
    }
}

public static class SettingsPolicy
{
    /// Действия со списком серверов не подтверждают остальные изменённые настройки черновика.
    public static AppSettings MergingRuntimeChanges(AppSettings old, AppSettings draft, AppSettings accepted)
    {
        var r = accepted.Copy();
        if (old.SelectedServerID != draft.SelectedServerID) r.SelectedServerID = draft.SelectedServerID;
        if (old.SelectedCountry != draft.SelectedCountry) r.SelectedCountry = draft.SelectedCountry;
        if (old.AutoSelect != draft.AutoSelect) r.AutoSelect = draft.AutoSelect;
        if (Json.Serialize(old.LastServerByCountry) != Json.Serialize(draft.LastServerByCountry)) r.LastServerByCountry = new(draft.LastServerByCountry);
        if (!old.FavoriteCountries.SequenceEqual(draft.FavoriteCountries)) r.FavoriteCountries = new(draft.FavoriteCountries);
        if (Json.Serialize(old.ServerRenames) != Json.Serialize(draft.ServerRenames)) r.ServerRenames = new(draft.ServerRenames);
        if (old.Sort != draft.Sort) r.Sort = draft.Sort;
        if (old.GeoLastUpdate != draft.GeoLastUpdate) r.GeoLastUpdate = draft.GeoLastUpdate;
        return r;
    }
}
