package app.tutun

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Imported profiles must not make the core read local files or connect to Unix sockets. */
object ConnectionValidation {
    private val protocols = setOf("vless", "vmess", "trojan", "shadowsocks", "hysteria", "wireguard", "socks")
    fun settings(s: Settings, p: RoutingProfile? = null) {
        val url = runCatching { URI(s.testURL) }.getOrNull()
        require(url?.scheme in listOf("http", "https") && !url?.host.isNullOrEmpty() && s.probeIntervalSec in 10..300 && s.failLimit in 1..10 && s.testTimeoutSec in 2..30) { "Недопустимые параметры подключения" }
        val rules = s.directSites + s.proxySites + s.blockSites + (p?.directSites ?: emptyList()) + (p?.proxySites ?: emptyList()) + (p?.blockSites ?: emptyList()) + (p?.directIPs ?: emptyList()) + (p?.proxyIPs ?: emptyList()) + (p?.blockIPs ?: emptyList())
        require(rules.none { it.trim().startsWith("ext:", true) }) { "Внешние файлы правил недопустимы в конфиге службы" }
        require(s.directCountry in DirectCountry.codes) { "Неизвестная страна для правил «напрямую»" }
    }
    private val singBoxTypes = setOf("tuic", "hysteria2")
    fun server(server: Server) {
        val outbound = JSONObject(server.outbound)
        val allowed = if (server.usesSingBox) outbound.optString("type") in singBoxTypes && !outbound.has("detour")
            else outbound.optString("protocol") in protocols
        require(server.engine in setOf(Server.ENGINE_XRAY, Server.ENGINE_SINGBOX) && allowed && !containsFileReference(outbound)) { "Недопустимый протокол или доступ к файлам в конфиге сервера" }
        require(server.host.isNotBlank() && server.port in 1..65535) { "Некорректный сервер" }
    }
    private fun containsFileReference(value: Any?): Boolean = when (value) {
        is JSONObject -> value.keys().asSequence().any { key ->
            val k = key.lowercase(java.util.Locale.ROOT)
            val item = value.get(key)
            k.endsWith("file") || k.endsWith("filepath") || k.endsWith("_path") || k in setOf("directory", "masterkeylog", "keylog", "keylogpath", "dssettings", "acme") ||
                (k in setOf("address", "server", "endpoint") && item is String && listOf("/", "@", "file:", "unix:").any { item.startsWith(it) }) || containsFileReference(item)
        }
        is JSONArray -> (0 until value.length()).any { containsFileReference(value.get(it)) }
        else -> false
    }
}
