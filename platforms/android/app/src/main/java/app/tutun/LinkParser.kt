package app.tutun

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest

class LinkException(message: String) : Exception(message)

data class ParsedBatch(val servers: List<Server>, val errors: List<String>, val profiles: List<RoutingProfile> = emptyList())

/**
 * Разбор ссылок vless / trojan / vmess / ss / hysteria2 / wireguard / socks в outbound xray.
 * Повторяет LinkParser.swift с мака. TUIC и Hysteria2 с obfs на маке идут через sing-box — на Android пока нет.
 */
object LinkParser {

    fun parse(raw: String, subId: String? = null): Server {
        val link = raw.trim()
        val i = link.indexOf("://")
        if (i <= 0) throw LinkException("ссылка повреждена: нет схемы")
        val scheme = link.substring(0, i).lowercase()
        val s = when (scheme) {
            "vless" -> parseStd(link, "vless")
            "trojan" -> parseStd(link, "trojan")
            "vmess" -> parseVmess(link)
            "ss" -> parseSS(link)
            "hysteria2", "hy2" -> parseHy2(link)
            "wireguard", "wg" -> parseWireGuard(link)
            "socks", "socks5" -> parseSocks(link)
            "tuic" -> parseTuic(link)
            "awg", "amneziawg" -> throw LinkException("AmneziaWG не поддерживается")
            else -> throw LinkException("не поддерживается: $scheme")
        }
        return s.copy(id = stableID(link), subId = subId)
    }

    /** Тело подписки: base64-список или ссылки построчно. */
    fun parseBatch(body: String, subId: String?): ParsedBatch {
        var text = body.trim()
        if (!text.contains("://") && !text.startsWith("[") && !text.startsWith("{")) {
            base64Decode(text)?.let { text = it }
        }
        if (text.startsWith("[") || text.startsWith("{")) return parseJSONConfigs(text, subId)
        val servers = mutableListOf<Server>()
        val errors = mutableListOf<String>()
        val profiles = mutableListOf<RoutingProfile>()
        for (line in text.lines()) {
            val l = line.trim()
            if (l.isEmpty() || l.startsWith("#") || l.startsWith("//")) continue
            val profile = parseRoutingLink(l)
            if (profile != null) { profiles.add(profile.copy(subId = subId)); continue }
            if (l.startsWith("happ://") || l.startsWith("tutun://")) continue
            try {
                servers.add(parse(l, subId))
            } catch (e: Exception) {
                val name = l.substringAfter('#', "").let { pct(it) }.ifEmpty { l.take(16) }
                errors.add("$name: ${e.message}")
            }
        }
        return ParsedBatch(servers, errors, profiles)
    }

    // MARK: профили маршрутов (формат Happ)

    fun parseRoutingLink(link: String): RoutingProfile? {
        val lower = link.lowercase()
        for (prefix in listOf("happ://routing/add/", "happ://routing/onadd/", "tutun://routing/add/", "tutun://routing/")) {
            if (!lower.startsWith(prefix)) continue
            val payload = link.substring(prefix.length)
            return parseRoutingJSON(base64Decode(payload) ?: pct(payload))
        }
        return null
    }

    fun parseRoutingJSON(text: String): RoutingProfile? {
        val o = try { JSONObject(text) } catch (e: Exception) { return null }
        fun str(k: String) = o.optString(k).takeIf { it.isNotEmpty() }
        val p = RoutingProfile(
            id = stableID(text), name = str("Name") ?: str("name") ?: "Профиль",
            directSites = o.strings("DirectSites"), directIPs = o.strings("DirectIp"),
            proxySites = o.strings("ProxySites"), proxyIPs = o.strings("ProxyIp"),
            blockSites = o.strings("BlockSites"), blockIPs = o.strings("BlockIp"),
            domainStrategy = str("DomainStrategy"), remoteDNS = str("RemoteDnsIP") ?: str("RemoteDns"),
            directDNS = str("DomesticDnsIP") ?: str("DomesticDns"),
            globalProxy = o.opt("GlobalProxy")?.toString()?.lowercase() != "false",
        )
        val hasRules = (p.directSites + p.directIPs + p.proxySites + p.proxyIPs + p.blockSites + p.blockIPs).isNotEmpty()
        return if (hasRules) p else null
    }

    private fun parseJSONConfigs(text: String, subId: String?): ParsedBatch {
        val configs = try {
            if (text.startsWith("[")) JSONArray(text).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            else listOf(JSONObject(text))
        } catch (e: Exception) {
            return ParsedBatch(emptyList(), listOf("JSON не читается"))
        }
        val skip = setOf("freedom", "blackhole", "dns", "loopback")
        val servers = mutableListOf<Server>()
        val errors = mutableListOf<String>()
        configs.forEachIndexed { i, cfg ->
            val outs = cfg.optJSONArray("outbounds")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
            val cand = outs.filter { it.optString("protocol") !in skip }
            val ob = cand.firstOrNull { it.optString("tag") == "proxy" } ?: cand.firstOrNull()
            if (ob == null) { errors.add("конфиг ${i + 1}: нет сервера"); return@forEachIndexed }
            ob.remove("tag")
            ob.optJSONObject("streamSettings")?.optJSONObject("sockopt")?.remove("dialerProxy")
            val (host, port) = endpoint(ob)
            val json = ob.toString()
            servers.add(Server(stableID(json), cfg.optString("remarks", "Сервер ${i + 1}"), ob.optString("protocol", "?"),
                host, port, ob.optJSONObject("streamSettings")?.optString("network", "tcp") ?: "tcp", json, subId))
        }
        return ParsedBatch(servers, errors)
    }

    fun endpoint(ob: JSONObject): Pair<String, Int> {
        val s = ob.optJSONObject("settings") ?: return "" to 0
        val v = s.optJSONArray("vnext")?.optJSONObject(0) ?: s.optJSONArray("servers")?.optJSONObject(0)
        if (v != null) return v.optString("address") to v.optInt("port")
        return s.optString("address") to s.optInt("port")
    }

    // MARK: vless / trojan

    private class Url(link: String) {
        val uri: URI = try { URI(link) } catch (e: Exception) { throw LinkException("ссылка повреждена") }
        val host: String = (uri.host ?: throw LinkException("ссылка повреждена: нет адреса")).trim('[', ']')
        val port: Int = uri.port
        val user: String = pct(uri.rawUserInfo ?: "")
        val name: String = pct(uri.rawFragment ?: "")
        val q: Map<String, String> = (uri.rawQuery ?: "").split("&").filter { it.isNotEmpty() }.associate {
            val k = it.substringBefore("="); val v = it.substringAfter("=", "")
            pct(k) to pct(v)
        }
        fun v(k: String) = q[k]?.takeIf { it.isNotEmpty() }
    }

    private fun parseStd(link: String, proto: String): Server {
        val u = Url(link)
        if (u.port <= 0) throw LinkException("ссылка повреждена: $proto")
        if (u.user.isEmpty()) throw LinkException("$proto: нет ключа")
        val ob = JSONObject().put("protocol", proto)
        if (proto == "vless") {
            val user = JSONObject().put("id", u.user).put("encryption", u.v("encryption") ?: "none")
            u.v("flow")?.let { user.put("flow", it) }
            ob.put("settings", JSONObject().put("vnext", JSONArray().put(
                JSONObject().put("address", u.host).put("port", u.port).put("users", JSONArray().put(user)))))
        } else {
            ob.put("settings", JSONObject().put("servers", JSONArray().put(
                JSONObject().put("address", u.host).put("port", u.port).put("password", u.user))))
        }
        val net = normalizeNetwork(u.q["type"] ?: "tcp")
        ob.put("streamSettings", streamSettings(net, u.q["security"] ?: if (proto == "trojan") "tls" else "none", u.q, u.host))
        return Server("", u.name.ifEmpty { u.host }, proto, u.host, u.port, net, ob.toString())
    }

    // MARK: vmess

    private fun parseVmess(link: String): Server {
        val dec = base64Decode(link.removePrefix("vmess://")) ?: throw LinkException("ссылка повреждена: vmess")
        val o = try { JSONObject(dec) } catch (e: Exception) { throw LinkException("ссылка повреждена: vmess") }
        fun s(k: String) = o.opt(k)?.toString() ?: ""
        val host = s("add"); val port = s("port").toIntOrNull() ?: 0
        if (host.isEmpty() || port == 0) throw LinkException("ссылка повреждена: vmess")
        val q = mutableMapOf("path" to s("path"), "host" to s("host"), "sni" to s("sni"), "alpn" to s("alpn"),
            "fp" to s("fp"), "headerType" to s("type"))
        if (s("net") == "grpc") { q["serviceName"] = s("path"); q["mode"] = if (s("type") == "multi") "multi" else "gun" }
        val net = normalizeNetwork(s("net").ifEmpty { "tcp" })
        val security = when (s("tls")) { "tls" -> "tls"; "reality" -> "reality"; else -> "none" }
        val user = JSONObject().put("id", s("id")).put("alterId", s("aid").toIntOrNull() ?: 0)
            .put("security", s("scy").ifEmpty { "auto" })
        val ob = JSONObject().put("protocol", "vmess")
            .put("settings", JSONObject().put("vnext", JSONArray().put(JSONObject().put("address", host).put("port", port)
                .put("users", JSONArray().put(user)))))
            .put("streamSettings", streamSettings(net, security, q, host))
        return Server("", s("ps").ifEmpty { host }, "vmess", host, port, net, ob.toString())
    }

    // MARK: shadowsocks

    private fun parseSS(link: String): Server {
        var body = link.removePrefix("ss://")
        var name = ""
        body.indexOf('#').takeIf { it >= 0 }?.let { name = pct(body.substring(it + 1)); body = body.substring(0, it) }
        body.indexOf('?').takeIf { it >= 0 }?.let {
            if (body.substring(it).contains("plugin=")) throw LinkException("Shadowsocks с плагином не поддерживается")
            body = body.substring(0, it)
        }
        var userinfo: String; var hostport: String
        val at = body.lastIndexOf('@')
        if (at >= 0) {
            userinfo = body.substring(0, at); hostport = body.substring(at + 1)
            val dec = base64Decode(pct(userinfo))
            userinfo = if (dec != null && dec.contains(":")) dec else pct(userinfo)
        } else {
            val dec = base64Decode(body) ?: throw LinkException("ссылка повреждена: ss")
            val a = dec.lastIndexOf('@').takeIf { it >= 0 } ?: throw LinkException("ссылка повреждена: ss")
            userinfo = dec.substring(0, a); hostport = dec.substring(a + 1)
        }
        hostport = hostport.trim('/')
        val c = userinfo.indexOf(':'); val pc = hostport.lastIndexOf(':')
        val port = if (pc >= 0) hostport.substring(pc + 1).toIntOrNull() else null
        if (c < 0 || port == null) throw LinkException("ссылка повреждена: ss")
        val host = hostport.substring(0, pc).trim('[', ']')
        val ob = JSONObject().put("protocol", "shadowsocks").put("settings", JSONObject().put("servers", JSONArray().put(
            JSONObject().put("address", host).put("port", port).put("method", userinfo.substring(0, c))
                .put("password", userinfo.substring(c + 1)))))
        return Server("", name.ifEmpty { host }, "shadowsocks", host, port, "tcp", ob.toString())
    }

    // MARK: hysteria2

    private fun parseHy2(link: String): Server {
        val u = Url(link.replaceFirst("hy2://", "hysteria2://"))
        val obfs = u.v("obfs")?.lowercase() ?: "none"
        if (obfs !in setOf("none", "salamander")) throw LinkException("Неподдерживаемые параметры Hysteria2")
        val obfsPassword = u.v("obfs-password") ?: u.v("obfsPassword")
        if (obfs == "salamander" && obfsPassword.isNullOrEmpty()) throw LinkException("Hysteria2: нет пароля obfs")
        val port = if (u.port > 0) u.port else 443
        val insecure = u.q["insecure"] in setOf("1", "true") || u.q["allowInsecure"] in setOf("1", "true")
        // insecure и порт-хоппинг xray не умеет — такие серверы держит sing-box, как на маке.
        if (insecure || u.v("mport") != null) {
            val tls = JSONObject().put("enabled", true).put("server_name", u.v("sni") ?: u.host).put("insecure", insecure)
                .put("alpn", JSONArray().put("h3"))
            val ob = JSONObject().put("type", "hysteria2").put("server", u.host).put("server_port", port).put("password", u.user).put("tls", tls)
            if (obfs == "salamander") ob.put("obfs", JSONObject().put("type", "salamander").put("password", obfsPassword))
            u.v("upmbps")?.toIntOrNull()?.let { ob.put("up_mbps", it) }
            u.v("downmbps")?.toIntOrNull()?.let { ob.put("down_mbps", it) }
            u.v("mport")?.let { m ->
                val ranges = m.split(",").map { it.trim().replace("-", ":") }.filter { it.isNotEmpty() }
                    .map { if (":" in it) it else "$it:$it" } // sing-box принимает только диапазоны «a:b»
                if (ranges.any { r -> r.split(":").let { p -> p.size !in 1..2 || p.any { it.toIntOrNull() !in 1..65535 } } }) throw LinkException("Hysteria2: неверный mport")
                ob.put("server_ports", JSONArray(ranges))
            }
            return Server("", u.name.ifEmpty { u.host }, "hysteria2", u.host, port, "quic", ob.toString(), engine = Server.ENGINE_SINGBOX)
        }
        val tls = JSONObject().put("serverName", u.v("sni") ?: u.host).put("alpn", JSONArray().put("h3"))
        u.v("pinSHA256")?.let { tls.put("pinnedPeerCertSha256", it) }
        val ob = JSONObject().put("protocol", "hysteria")
            .put("settings", JSONObject().put("version", 2).put("address", u.host).put("port", port))
            .put("streamSettings", JSONObject().put("network", "hysteria").put("security", "tls").put("tlsSettings", tls)
                .put("hysteriaSettings", JSONObject().put("version", 2).put("auth", u.user)))
        if (obfs == "salamander") ob.getJSONObject("streamSettings").put("finalmask", JSONObject().put("udp", JSONArray().put(
            JSONObject().put("type", "salamander").put("settings", JSONObject().put("password", obfsPassword)))))
        return Server("", u.name.ifEmpty { u.host }, "hysteria2", u.host, port, "quic", ob.toString())
    }

    // MARK: TUIC (sing-box)

    private fun parseTuic(link: String): Server {
        val u = Url(link)
        if (u.port <= 0) throw LinkException("ссылка повреждена: tuic")
        val uuid = u.user.substringBefore(":")
        val password = u.user.substringAfter(":", "")
        if (uuid.isEmpty()) throw LinkException("tuic: нет uuid")
        val alpn = (u.v("alpn") ?: "h3").split(",").map { it.trim() }.filter { it.isNotEmpty() }
        val tls = JSONObject().put("enabled", true).put("server_name", u.v("sni") ?: u.host)
            .put("insecure", u.q["allow_insecure"] in setOf("1", "true") || u.q["insecure"] in setOf("1", "true"))
            .put("alpn", JSONArray(alpn))
        val ob = JSONObject().put("type", "tuic").put("server", u.host).put("server_port", u.port)
            .put("uuid", uuid).put("password", password)
            .put("congestion_control", u.v("congestion_control") ?: "bbr")
            .put("udp_relay_mode", u.v("udp_relay_mode") ?: "native")
            .put("tls", tls)
        return Server("", u.name.ifEmpty { u.host }, "tuic", u.host, u.port, "quic", ob.toString(), engine = Server.ENGINE_SINGBOX)
    }

    // MARK: WireGuard

    private fun parseWireGuard(link: String): Server {
        val u = Url(link)
        val secret = u.user.ifEmpty { u.q["privatekey"] ?: "" }
        val pub = u.q["publickey"] ?: u.q["public_key"]
        if (secret.isEmpty() || pub == null || u.port <= 0) throw LinkException("wireguard: нет ключей")
        val addrs = (u.q["address"] ?: u.q["ip"] ?: "10.0.0.2/32").split(",").map { a ->
            val t = a.trim(); if (t.contains("/")) t else if (t.contains(":")) "$t/128" else "$t/32"
        }
        val peer = JSONObject().put("publicKey", pub).put("endpoint", "${u.host}:${u.port}")
            .put("allowedIPs", JSONArray().put("0.0.0.0/0").put("::/0"))
        (u.q["presharedkey"] ?: u.q["psk"])?.takeIf { it.isNotEmpty() }?.let { peer.put("preSharedKey", it) }
        val settings = JSONObject().put("secretKey", secret).put("address", JSONArray(addrs)).put("peers", JSONArray().put(peer))
            .put("mtu", u.q["mtu"]?.toIntOrNull() ?: 1420)
        u.q["reserved"]?.split(",")?.mapNotNull { it.trim().toIntOrNull() }?.takeIf { it.size == 3 }?.let { settings.put("reserved", JSONArray(it)) }
        val ob = JSONObject().put("protocol", "wireguard").put("settings", settings)
        return Server("", u.name.ifEmpty { u.host }, "wireguard", u.host, u.port, "udp", ob.toString())
    }

    // MARK: SOCKS

    private fun parseSocks(link: String): Server {
        var l = link
        val start = l.indexOf("://") + 3; val at = l.indexOf('@')
        if (at > start) {
            val cred = l.substring(start, at)
            if (!cred.contains(":")) base64Decode(pct(cred))?.takeIf { it.contains(":") }?.let {
                l = l.substring(0, start) + it.split(":", limit = 2).joinToString(":") { p -> java.net.URLEncoder.encode(p, "UTF-8") } + l.substring(at)
            }
        }
        val u = Url(l)
        if (u.port <= 0) throw LinkException("ссылка повреждена: socks")
        val server = JSONObject().put("address", u.host).put("port", u.port)
        if (u.user.isNotEmpty()) {
            val user = u.user.substringBefore(":"); val pass = u.user.substringAfter(":", "")
            server.put("users", JSONArray().put(JSONObject().put("user", user).put("pass", pass)))
        }
        val ob = JSONObject().put("protocol", "socks").put("settings", JSONObject().put("servers", JSONArray().put(server)))
        return Server("", u.name.ifEmpty { u.host }, "socks", u.host, u.port, "tcp", ob.toString())
    }

    // MARK: transport / security

    private fun normalizeNetwork(n: String) = when (n.lowercase()) {
        "", "tcp", "raw" -> "tcp"
        "splithttp", "h2", "http" -> "xhttp"
        else -> n.lowercase()
    }

    private fun streamSettings(network: String, security: String, q: Map<String, String>, address: String): JSONObject {
        fun v(k: String) = q[k]?.takeIf { it.isNotEmpty() }
        val ss = JSONObject().put("network", network)
        when (network) {
            "ws" -> ss.put("wsSettings", JSONObject().put("path", v("path") ?: "/").also { o -> v("host")?.let { o.put("host", it) } })
            "grpc" -> ss.put("grpcSettings", JSONObject().put("serviceName", v("serviceName") ?: v("path") ?: "")
                .put("multiMode", q["mode"] == "multi").also { o -> v("authority")?.let { o.put("authority", it) } })
            "xhttp" -> ss.put("xhttpSettings", JSONObject().put("path", v("path") ?: "/").put("mode", v("mode") ?: "auto").also { o ->
                v("host")?.let { o.put("host", it) }
                v("extra")?.let { e -> try { o.put("extra", JSONObject(e)) } catch (_: Exception) { } }
            })
            "httpupgrade" -> ss.put("httpupgradeSettings", JSONObject().put("path", v("path") ?: "/").also { o -> v("host")?.let { o.put("host", it) } })
            "kcp" -> ss.put("kcpSettings", JSONObject().put("header", JSONObject().put("type", v("headerType") ?: "none"))
                .also { o -> v("seed")?.let { o.put("seed", it) } })
            else -> if (v("headerType") == "http") {
                val req = JSONObject().put("path", JSONArray().put(v("path") ?: "/"))
                v("host")?.let { req.put("headers", JSONObject().put("Host", JSONArray(it.split(",")))) }
                ss.put("tcpSettings", JSONObject().put("header", JSONObject().put("type", "http").put("request", req)))
            }
        }
        val alpn = v("alpn")?.split(",")
        when (security) {
            "tls" -> {
                val t = JSONObject().put("serverName", v("sni") ?: v("host") ?: address)
                v("fp")?.let { t.put("fingerprint", it) }
                alpn?.let { t.put("alpn", JSONArray(it)) }
                v("pcs")?.let { t.put("pinnedPeerCertSha256", it) }
                v("vcn")?.let { t.put("verifyPeerCertByName", it) }
                v("ech")?.let { t.put("echConfigList", it) }
                ss.put("security", "tls").put("tlsSettings", t)
            }
            "reality" -> {
                val r = JSONObject().put("serverName", v("sni") ?: "").put("fingerprint", v("fp") ?: "chrome")
                    .put("publicKey", v("pbk") ?: "").put("shortId", v("sid") ?: "")
                v("spx")?.let { r.put("spiderX", it) }
                v("pqv")?.let { r.put("mldsa65Verify", it) }
                ss.put("security", "reality").put("realitySettings", r)
            }
            else -> ss.put("security", "none")
        }
        return ss
    }

    /** Почему xray не примет сервер: VLESS без шифрования на публичный адрес запрещён в xray 26. */
    fun rejectReason(s: Server): String? {
        try { ConnectionValidation.server(s) } catch (e: Exception) { return e.message ?: "Некорректный сервер" }
        if (s.usesSingBox && !SingBoxHelper.supported) return "нужен sing-box, его нет для этого процессора"
        val ob = JSONObject(s.outbound)
        if (ob.optString("protocol") != "vless") return null
        if ((ob.optJSONObject("streamSettings")?.optString("security") ?: "none") != "none") return null
        val enc = ob.optJSONObject("settings")?.optJSONArray("vnext")?.optJSONObject(0)?.optJSONArray("users")
            ?.optJSONObject(0)?.optString("encryption", "none") ?: "none"
        if (enc != "none") return null
        val h = s.host.lowercase()
        if (AddressPolicy.isPrivate(h)) return null
        return "без шифрования — новая версия xray такие запрещает"
    }

    // MARK: helpers

    /** Процентное декодирование без превращения «+» в пробел (ключи Reality бывают с «+»). */
    fun pct(s: String): String = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (e: Exception) { s }

    fun base64Decode(s: String): String? {
        var t = s.trim().replace("\n", "").replace("\r", "").replace("-", "+").replace("_", "/")
        while (t.length % 4 != 0) t += "="
        return try {
            val bytes = Base64.decode(t, Base64.DEFAULT)
            val str = String(bytes, Charsets.UTF_8)
            if (str.contains('�')) null else str
        } catch (e: Exception) { null }
    }

    fun stableID(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).take(8).joinToString("") { "%02x".format(it) }
}
