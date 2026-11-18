namespace Tutun.Core;

/// «Сайты страны — напрямую»: чем пользоваться внутри страны без VPN (банки, госуслуги, местные сервисы).
/// Списки — из гео-баз runetfreedom (geoip есть для всех стран; готовые geosite — только для части),
/// плюс национальная доменная зона. Код страны хранится в AppSettings.directCountry, включение — russiaDirect
/// (историческое имя поля, оставлено для совместимости app.json с маком).
public sealed record HomeRegion(string Code, string NameRu, string[] Domains, string[] DnsDomains, string[] Ips, string? DefaultDirectDns);

public static class HomeRegions
{
    public static readonly HomeRegion[] All =
    [
        new("ru", "Россия",
            ["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$",
             "domain:yandex.net", "domain:yastatic.net", "domain:vk.com", "domain:userapi.com",
             "domain:mycdn.me", "domain:ok.ru", "domain:max.ru", "domain:gosuslugi.ru"],
            ["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.xn--p1ai$"], ["geoip:ru"], "77.88.8.8"),
        // Китай: v2fly-список geosite:cn (китайские сервисы и CDN), зона .cn.
        new("cn", "Китай", ["geosite:cn", "regexp:\\.cn$"], ["geosite:cn", "regexp:\\.cn$"], ["geoip:cn"], null),
        // Иран: geosite:category-ir (банки, госсайты, СМИ), зона .ir.
        new("ir", "Иран", ["geosite:category-ir", "regexp:\\.ir$"], ["geosite:category-ir", "regexp:\\.ir$"], ["geoip:ir"], null),
        // Мьянма: банки (geosite:category-bank-mm) и зона .mm.
        new("mm", "Мьянма", ["geosite:category-bank-mm", "regexp:\\.mm$"], ["geosite:category-bank-mm", "regexp:\\.mm$"], ["geoip:mm"], null),
        // Турция и ОАЭ: готовых списков сайтов нет — зона и IP-адреса страны.
        new("tr", "Турция", ["regexp:\\.tr$"], ["regexp:\\.tr$"], ["geoip:tr"], null),
        new("ae", "ОАЭ", ["regexp:\\.ae$"], ["regexp:\\.ae$"], ["geoip:ae"], null),
    ];

    public static HomeRegion Get(string? code) => All.FirstOrDefault(r => r.Code == code) ?? All[0];

    /// DNS для сайтов страны: указанный пользователем, а если стоит российский по умолчанию, но выбрана
    /// другая страна — системный (провайдерский) DNS: он и так «домашний».
    public static string DirectDns(HomeRegion r, string configured) =>
        r.Code != "ru" && configured.Trim() == "77.88.8.8" ? "localhost" : configured;
}
