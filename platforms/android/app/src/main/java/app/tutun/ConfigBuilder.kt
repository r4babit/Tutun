package app.tutun

import org.json.JSONArray
import org.json.JSONObject

/**
 * Конфиг xray для Android: вход TUN (дескриптор от VpnService), серверы p0…pN.
 * Весь трафик идёт через p{current}; пробные входы t{i} (127.0.0.1:21000+i) всегда ведут в p{i} —
 * по ним служба замеряет запасные серверы, когда текущий перестал отвечать.
 * Правила маршрутов — как ConfigBuilder.swift на маке.
 */
object ConfigBuilder {
    const val SOCKS_PORT = 10808
    const val PROBE_BASE_PORT = 21000

    private val tcpTransports = setOf("tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade")

    fun build(servers: List<Server>, current: Int, s: Settings, profile: RoutingProfile?, withTun: Boolean = true, chain: Server? = null,
              helperBasePort: Int = SingBoxHelper.BASE_PORT): String {
        require(servers.isNotEmpty() && current in servers.indices)
        ConnectionValidation.settings(s, profile)
        servers.forEach(ConnectionValidation::server)
        if (s.chainServerId != null) require(chain?.id == s.chainServerId) { "Сервер цепочки недоступен" }
        chain?.let {
            ConnectionValidation.server(it)
            require(ChainPolicy.supports(it)) { "Цепочка поддерживается только для TCP-транспортов" }
            require(servers.none { target -> target.id == it.id }) { "Цепочка не может замыкаться на себя" }
        }
        val outbounds = JSONArray()
        servers.forEachIndexed { i, srv ->
            if (srv.usesSingBox) {
                require(chain == null) { "Цепочка поддерживается только для TCP-транспортов" }
                outbounds.put(helperOutbound(SingBoxHelper.portFor(servers, srv, helperBasePort)).put("tag", "p$i"))
                return@forEachIndexed
            }
            val ob = JSONObject(srv.outbound)
            val proto = ob.optString("protocol")
            val ss = ob.optJSONObject("streamSettings") ?: JSONObject()
            val net = ss.optString("network", "tcp")
            val tcpBased = net in tcpTransports && proto in setOf("vless", "vmess", "trojan", "shadowsocks", "socks")
            if (chain != null) require(tcpBased) { "Цепочка поддерживается только для TCP-транспортов" }
            if ((s.fragment || chain != null) && tcpBased) {
                val so = ss.optJSONObject("sockopt") ?: JSONObject()
                so.put("dialerProxy", if (chain != null) "chain" else "fragment"); ss.put("sockopt", so)
                if (!ss.has("network")) ss.put("network", "tcp")
                ob.put("streamSettings", ss)
            }
            if (s.mux && tcpBased && net != "xhttp" && !hasFlow(ob)) {
                ob.put("mux", JSONObject().put("enabled", true).put("concurrency", 8).put("xudpConcurrency", 16).put("xudpProxyUDP443", "reject"))
            }
            outbounds.put(ob.put("tag", "p$i"))
        }
        if (chain != null) {
            val first = JSONObject(chain.outbound)
            val stream = first.optJSONObject("streamSettings") ?: JSONObject()
            val sock = stream.optJSONObject("sockopt") ?: JSONObject()
            sock.remove("dialerProxy")
            if (s.fragment) sock.put("dialerProxy", "fragment")
            stream.put("sockopt", sock); first.put("streamSettings", stream)
            outbounds.put(first.put("tag", "chain"))
        }
        if (s.fragment) {
            outbounds.put(JSONObject().put("tag", "fragment").put("protocol", "freedom").put("settings", JSONObject()
                .put("fragment", JSONObject().put("packets", "tlshello").put("length", "100-200").put("interval", "10-20"))))
        }
        outbounds.put(JSONObject().put("tag", "direct").put("protocol", "freedom"))
        outbounds.put(JSONObject().put("tag", "block").put("protocol", "blackhole"))
        outbounds.put(JSONObject().put("tag", "dns-out").put("protocol", "dns"))

        val sniff = JSONObject().put("enabled", true).put("destOverride", JSONArray(listOf("http", "tls", "quic"))).put("routeOnly", true)
        val inbounds = JSONArray()
        if (withTun) {
            inbounds.put(JSONObject().put("tag", "tun").put("protocol", "tun")
                .put("settings", JSONObject().put("name", "xray0").put("MTU", 1500).put("userLevel", 0))
                .put("sniffing", sniff))
        }
        inbounds.put(JSONObject().put("tag", "socks").put("listen", "127.0.0.1").put("port", SOCKS_PORT).put("protocol", "socks")
            .put("settings", JSONObject().put("udp", true)).put("sniffing", sniff))
        if (servers.size > 1) servers.indices.forEach { i ->
            inbounds.put(JSONObject().put("tag", "t$i").put("listen", "127.0.0.1").put("port", PROBE_BASE_PORT + i)
                .put("protocol", "socks").put("settings", JSONObject().put("udp", false)))
        }

        val proxy = "p$current"
        val rules = JSONArray()
        fun rule(key: String, values: List<String>, out: String) {
            if (values.isNotEmpty()) rules.put(JSONObject().put(key, JSONArray(values)).put("outboundTag", out))
        }
        if (servers.size > 1) servers.indices.forEach { i ->
            rules.put(JSONObject().put("inboundTag", JSONArray().put("t$i")).put("outboundTag", "p$i"))
        }
        // DNS-запросы телефона перехватывает встроенный DNS xray.
        rules.put(JSONObject().put("inboundTag", JSONArray().put("tun")).put("port", "53").put("outboundTag", "dns-out"))
        val p = profile
        if (s.routingMode == "direct") {
            rules.put(JSONObject().put("network", "tcp,udp").put("outboundTag", "direct"))
        } else {
            // 1. Блокировка
            val blockDomains = cleaned(s.blockSites + (p?.blockSites ?: emptyList())).map(::domainRule) +
                (if (s.blockAds) listOf("geosite:category-ads-all") else emptyList())
            rule("domain", blockDomains, "block")
            rule("ip", cleaned(p?.blockIPs ?: emptyList()), "block")
            // 2. Всегда через VPN
            rule("domain", cleaned(s.proxySites + (p?.proxySites ?: emptyList())).map(::domainRule), proxy)
            rule("ip", cleaned(p?.proxyIPs ?: emptyList()), proxy)
            // 3. Напрямую
            rules.put(JSONObject().put("ip", JSONArray().put("geoip:private")).put("outboundTag", "direct"))
            if (s.routingMode == "rule") {
                rule("domain", cleaned(s.directSites + (p?.directSites ?: emptyList())).map(::domainRule), "direct")
                rule("ip", cleaned(p?.directIPs ?: emptyList()), "direct")
                if (s.russiaDirect) {
                    rule("domain", DirectCountry.domains(s.directCountry), "direct")
                    rule("ip", DirectCountry.ips(s.directCountry), "direct")
                }
            }
            // 4. Остальное
            val rest = if (s.routingMode == "rule" && p?.globalProxy == false) "direct" else proxy
            rules.put(JSONObject().put("network", "tcp,udp").put("outboundTag", rest))
        }

        val dnsServers = JSONArray().put(p?.remoteDNS ?: s.remoteDNS)
        if (s.russiaDirect && s.routingMode == "rule") {
            dnsServers.put(JSONObject().put("address", DirectCountry.dnsAddress(s.directCountry, p?.directDNS ?: s.directDNS))
                .put("domains", JSONArray(DirectCountry.dnsDomains(s.directCountry))))
        }

        return JSONObject()
            .put("log", JSONObject().put("loglevel", "warning").put("access", "none"))
            .put("stats", JSONObject())
            .put("policy", JSONObject().put("system", JSONObject().put("statsOutboundUplink", true).put("statsOutboundDownlink", true)))
            .put("dns", JSONObject().put("servers", dnsServers).put("queryStrategy", "UseIPv4").put("tag", "dns-in"))
            .put("inbounds", inbounds)
            .put("outbounds", outbounds)
            .put("routing", JSONObject().put("domainStrategy", p?.domainStrategy ?: "IPIfNonMatch").put("rules", rules))
            .toString()
    }

    private fun hasFlow(ob: JSONObject) = ob.optJSONObject("settings")?.optJSONArray("vnext")?.optJSONObject(0)
        ?.optJSONArray("users")?.optJSONObject(0)?.optString("flow").isNullOrEmpty().not()

    private fun cleaned(list: List<String>) = list.map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }

    /** «example.com» → домен со всеми поддоменами; «geosite:», «regexp:», «full:», «keyword:» — как есть. */
    private fun domainRule(s: String) = if (s.contains(":")) s else "domain:" + s.lowercase()

    /** Вход во вспомогательный sing-box (TUIC, Hysteria2 с insecure/портами). */
    private fun helperOutbound(port: Int) = JSONObject().put("protocol", "socks")
        .put("settings", JSONObject().put("servers", JSONArray().put(JSONObject().put("address", "127.0.0.1").put("port", port))))

    /** Минимальный конфиг для замера одного сервера (Libv2ray.measureOutboundDelay). helperPort — для серверов sing-box. */
    fun probe(server: Server, helperPort: Int? = null): String {
        ConnectionValidation.server(server)
        val ob = if (server.usesSingBox) helperOutbound(requireNotNull(helperPort) { "sing-box не запущен" }) else JSONObject(server.outbound)
        return JSONObject()
        .put("log", JSONObject().put("loglevel", "none"))
        .put("inbounds", JSONArray())
        .put("outbounds", JSONArray().put(ob.put("tag", "proxy")))
        .toString()
    }
}
