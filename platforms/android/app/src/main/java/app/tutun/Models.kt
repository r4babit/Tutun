package app.tutun

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** Сервер: готовый outbound xray в JSON (как на маке). */
data class Server(
    val id: String,
    val name: String,
    val proto: String,
    val host: String,
    val port: Int,
    val transport: String,
    val outbound: String,
    val subId: String? = null,
    /** Ядро: "xray" (почти всё) или "singbox" — вспомогательный sing-box для TUIC и Hysteria2 с insecure/mport. */
    val engine: String = ENGINE_XRAY,
) {
    val usesSingBox: Boolean get() = engine == ENGINE_SINGBOX

    /** Флаг из начала имени (🇳🇱 …). */
    val flag: String? get() {
        val cps = name.codePoints().toArray()
        if (cps.size >= 2 && cps[0] in 0x1F1E6..0x1F1FF && cps[1] in 0x1F1E6..0x1F1FF) {
            return String(cps, 0, 2)
        }
        return null
    }

    val countryCode: String? get() {
        val cps = name.codePoints().toArray()
        if (cps.size >= 2 && cps[0] in 0x1F1E6..0x1F1FF && cps[1] in 0x1F1E6..0x1F1FF) {
            return "${'A' + (cps[0] - 0x1F1E6)}${'A' + (cps[1] - 0x1F1E6)}"
        }
        return null
    }

    /** Имя без флага. */
    val cleanName: String get() {
        if (flag == null) return name
        return name.codePoints().toArray().dropWhile { it in 0x1F1E6..0x1F1FF || it == ' '.code || it == 0xFE0F }
            .joinToString("") { String(Character.toChars(it)) }
    }

    fun toJson() = JSONObject().put("id", id).put("name", name).put("proto", proto).put("host", host)
        .put("port", port).put("transport", transport).put("outbound", outbound).put("subId", subId).put("engine", engine)

    companion object {
        fun from(o: JSONObject) = Server(
            o.getString("id"), o.getString("name"), o.getString("proto"), o.getString("host"), o.getInt("port"),
            o.optString("transport", "tcp"), o.getString("outbound"), o.optString("subId").ifEmpty { null },
            o.optString("engine", ENGINE_XRAY).ifEmpty { ENGINE_XRAY },
        )
        const val ENGINE_XRAY = "xray"
        const val ENGINE_SINGBOX = "singbox"

        fun countryName(code: String): String =
            Locale("", code).getDisplayCountry(L10n.locale).ifEmpty { code }
    }
}

data class Subscription(
    val id: String,
    val url: String,
    val name: String = "Подписка",
    val upload: Long = 0,
    val download: Long = 0,
    val total: Long = 0,
    val expire: Long = 0,          // секунды Unix, 0 — бессрочно
    val lastUpdate: Long = 0,
    val lastError: String? = null,
    val supportURL: String? = null,
    val webPageURL: String? = null,
    val updateIntervalHours: Int = 12,
    val enabled: Boolean = true,
    val announce: String? = null,
    val collapsed: Boolean = false,
) {
    fun toJson() = JSONObject().put("id", id).put("url", url).put("name", name).put("upload", upload)
        .put("download", download).put("total", total).put("expire", expire).put("lastUpdate", lastUpdate)
        .put("lastError", lastError).put("supportURL", supportURL).put("webPageURL", webPageURL)
        .put("updateIntervalHours", updateIntervalHours).put("enabled", enabled).put("announce", announce).put("collapsed", collapsed)

    companion object {
        fun from(o: JSONObject) = Subscription(
            o.getString("id"), o.getString("url"), o.optString("name", "Подписка"), o.optLong("upload"),
            o.optLong("download"), o.optLong("total"), o.optLong("expire"), o.optLong("lastUpdate"),
            o.optString("lastError").ifEmpty { null }, o.optString("supportURL").ifEmpty { null },
            o.optString("webPageURL").ifEmpty { null }, o.optInt("updateIntervalHours", 12).coerceIn(1, 168),
            o.optBoolean("enabled", true), o.optString("announce").ifEmpty { null }, o.optBoolean("collapsed", false),
        )
    }
}

/** Что выбрано: самый быстрый, страна или сервер. */
data class Selection(val kind: String = "fastest", val value: String? = null) {
    fun toJson() = JSONObject().put("kind", kind).put("value", value)
    companion object {
        fun from(o: JSONObject?) = if (o == null) Selection() else Selection(o.optString("kind", "fastest"), o.optString("value").ifEmpty { null })
    }
}

/** Профиль маршрутов в формате Happ (happ://routing/add/…), как на маке. */
data class RoutingProfile(
    val id: String,
    val name: String,
    val directSites: List<String> = emptyList(),
    val directIPs: List<String> = emptyList(),
    val proxySites: List<String> = emptyList(),
    val proxyIPs: List<String> = emptyList(),
    val blockSites: List<String> = emptyList(),
    val blockIPs: List<String> = emptyList(),
    val domainStrategy: String? = null,
    val remoteDNS: String? = null,
    val directDNS: String? = null,
    val globalProxy: Boolean = true,
    val subId: String? = null,
) {
    fun toJson() = JSONObject().put("id", id).put("name", name).put("directSites", JSONArray(directSites))
        .put("directIPs", JSONArray(directIPs)).put("proxySites", JSONArray(proxySites)).put("proxyIPs", JSONArray(proxyIPs))
        .put("blockSites", JSONArray(blockSites)).put("blockIPs", JSONArray(blockIPs)).put("domainStrategy", domainStrategy)
        .put("remoteDNS", remoteDNS).put("directDNS", directDNS).put("globalProxy", globalProxy).put("subId", subId)

    companion object {
        fun from(o: JSONObject) = RoutingProfile(
            o.getString("id"), o.optString("name", "Профиль"), o.strings("directSites"), o.strings("directIPs"),
            o.strings("proxySites"), o.strings("proxyIPs"), o.strings("blockSites"), o.strings("blockIPs"),
            o.optString("domainStrategy").ifEmpty { null }, o.optString("remoteDNS").ifEmpty { null },
            o.optString("directDNS").ifEmpty { null }, o.optBoolean("globalProxy", true), o.optString("subId").ifEmpty { null },
        )
    }
}

data class Settings(
    // Маршруты
    val routingMode: String = "rule",          // rule — по правилам, global — всё через VPN, direct — всё напрямую
    val russiaDirect: Boolean = true,
    val blockAds: Boolean = false,
    val directSites: List<String> = emptyList(),
    val proxySites: List<String> = emptyList(),
    val blockSites: List<String> = emptyList(),
    val profileId: String? = null,
    // Приложения
    val appsMode: String = "off",              // off — все через VPN, exclude — выбранные мимо, include — только выбранные
    val apps: List<String> = emptyList(),
    // Подключение
    val sendHWID: Boolean = false,
    val probeIntervalSec: Int = 30,
    val failLimit: Int = 3,
    val remoteDNS: String = "1.1.1.1",
    val directDNS: String = "77.88.8.8",
    val testURL: String = "https://www.gstatic.com/generate_204",
    val testTimeoutSec: Int = 5,
    val updateOnLaunch: Boolean = true,
    val skipNoFlag: Boolean = true,            // в автовыборе — только серверы с флагом страны
    val fragment: Boolean = false,
    val mux: Boolean = false,
    val connectOnBoot: Boolean = false,
    // Избранное: «c:NL» — страна, «s:<id>» — сервер
    val favorites: List<String> = emptyList(),
    val hwidConsentVersion: Int = 0,
    val language: String = "system",
    val countryPick: String = "fastest",
    val countryPreferFavorites: Boolean = true,
    val failover: Boolean = true,
    val lastServerByCountry: Map<String, String> = emptyMap(),
    val chainServerId: String? = null,
    /** Разрешить подписки по http:// (по умолчанию только https). ID устройства по http не отправляется никогда. */
    val allowHttpSubscriptions: Boolean = false,
    /** Страна для «Сайты страны — напрямую» (если russiaDirect): ru, cn, ir, mm, tr, ae. Нет поля → ru. */
    val directCountry: String = "ru",
    val geoAutoUpdate: Boolean = false,
) {
    fun requiresReconnect(other: Settings): Boolean = copy(favorites = other.favorites, sendHWID = other.sendHWID,
        hwidConsentVersion = other.hwidConsentVersion, language = other.language, lastServerByCountry = other.lastServerByCountry, updateOnLaunch = other.updateOnLaunch, connectOnBoot = other.connectOnBoot,
        allowHttpSubscriptions = other.allowHttpSubscriptions, geoAutoUpdate = other.geoAutoUpdate) != other
    fun toJson() = JSONObject().put("routingMode", routingMode).put("russiaDirect", russiaDirect).put("blockAds", blockAds)
        .put("directSites", JSONArray(directSites)).put("proxySites", JSONArray(proxySites)).put("blockSites", JSONArray(blockSites))
        .put("profileId", profileId).put("appsMode", appsMode).put("apps", JSONArray(apps))
        .put("sendHWID", sendHWID).put("probeIntervalSec", probeIntervalSec).put("failLimit", failLimit)
        .put("remoteDNS", remoteDNS).put("directDNS", directDNS).put("testURL", testURL).put("testTimeoutSec", testTimeoutSec)
        .put("updateOnLaunch", updateOnLaunch).put("skipNoFlag", skipNoFlag).put("fragment", fragment).put("mux", mux)
        .put("connectOnBoot", connectOnBoot).put("favorites", JSONArray(favorites)).put("hwidConsentVersion", hwidConsentVersion)
        .put("language", language).put("countryPick", countryPick).put("countryPreferFavorites", countryPreferFavorites)
        .put("failover", failover).put("lastServerByCountry", JSONObject(lastServerByCountry)).put("chainServerId", chainServerId)
        .put("allowHttpSubscriptions", allowHttpSubscriptions).put("directCountry", directCountry).put("geoAutoUpdate", geoAutoUpdate)

    companion object {
        fun from(o: JSONObject?): Settings {
            val d = Settings()
            if (o == null) return d
            return Settings(
                o.optString("routingMode", d.routingMode), o.optBoolean("russiaDirect", d.russiaDirect),
                o.optBoolean("blockAds", d.blockAds), o.strings("directSites"), o.strings("proxySites"), o.strings("blockSites"),
                o.optString("profileId").ifEmpty { null }, o.optString("appsMode", d.appsMode), o.strings("apps"),
                (o.optInt("hwidConsentVersion", 0) >= 1 && o.optBoolean("sendHWID", false)), o.optInt("probeIntervalSec", d.probeIntervalSec),
                o.optInt("failLimit", d.failLimit), o.optString("remoteDNS", d.remoteDNS), o.optString("directDNS", d.directDNS),
                o.optString("testURL", d.testURL), o.optInt("testTimeoutSec", d.testTimeoutSec),
                o.optBoolean("updateOnLaunch", d.updateOnLaunch), o.optBoolean("skipNoFlag", d.skipNoFlag),
                o.optBoolean("fragment", d.fragment), o.optBoolean("mux", d.mux), o.optBoolean("connectOnBoot", d.connectOnBoot),
                o.strings("favorites"), o.optInt("hwidConsentVersion", 0),
                o.optString("language", "system"), o.optString("countryPick", "fastest"),
                o.optBoolean("countryPreferFavorites", true), o.optBoolean("failover", true),
                o.optJSONObject("lastServerByCountry")?.let { obj -> obj.keys().asSequence().associateWith { obj.getString(it) } } ?: emptyMap(),
                o.optString("chainServerId").ifEmpty { null },
                o.optBoolean("allowHttpSubscriptions", false),
                o.optString("directCountry", "ru").ifEmpty { "ru" }, o.optBoolean("geoAutoUpdate", false),
            )
        }
    }
}

fun JSONObject.strings(k: String): List<String> {
    val a = optJSONArray(k) ?: return optString(k).split(",").map { it.trim() }.filter { it.isNotEmpty() }
    return (0 until a.length()).map { a.getString(it).trim() }.filter { it.isNotEmpty() }
}

fun <T> JSONArray.mapObjects(f: (JSONObject) -> T): List<T> = (0 until length()).map { f(getJSONObject(it)) }
fun <T> List<T>.toJsonArray(f: (T) -> Any): JSONArray = JSONArray().also { a -> forEach { a.put(f(it)) } }
