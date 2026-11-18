package app.tutun

import org.json.JSONObject
object ChainPolicy {
    fun targets(all: List<Server>, selection: Selection, settings: Settings): List<Server> {
        val pool = all.filter { it.id != settings.chainServerId }
        if (settings.chainServerId == null) return pool
        val compatible = pool.filter(::supports)
        if (selection.kind == "server" && compatible.none { it.id == selection.value }) return emptyList()
        if (selection.kind == "country" && compatible.none { (it.countryCode ?: "??") == selection.value }) return emptyList()
        return compatible
    }

    fun supports(server: Server): Boolean = runCatching {
        val ob = JSONObject(server.outbound)
        ob.optString("protocol") in setOf("vless", "vmess", "trojan", "shadowsocks", "socks") &&
            (ob.optJSONObject("streamSettings")?.optString("network", "tcp") ?: "tcp") in setOf("tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade")
    }.getOrDefault(false)
}
