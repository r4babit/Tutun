package app.tutun

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SingBoxTests {
    @Test fun directCountryRulesAndDns() {
        val v = LinkParser.parse("vless://11111111-2222-3333-4444-555555555555@v.example.invalid:443?security=tls#V")
        for (code in DirectCountry.codes) {
            val cfg = ConfigBuilder.build(listOf(v), 0, Settings(directCountry = code), null)
            assertEquals(code, code in setOf("ru", "cn", "ir"), cfg.contains("geoip:$code"))
            assertTrue(code, cfg.contains(if (code == "ru") "77.88.8.8" else "localhost"))
            System.getenv("TUTUN_COUNTRY_FIXTURE_DIR")?.let { java.io.File(it, "$code.json").writeText(
                ConfigBuilder.build(listOf(v), 0, Settings(directCountry = code), null, withTun = false)) }
        }
        assertFalse(ConfigBuilder.build(listOf(v), 0, Settings(russiaDirect = false, directCountry = "cn"), null).contains("geoip:cn"))
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.build(listOf(v), 0, Settings(directCountry = "xx"), null) }
        assertEquals("ru", Settings.from(org.json.JSONObject()).directCountry)
        assertEquals("ir", Settings.from(Settings(directCountry = "ir").toJson()).directCountry)
    }

    @Test fun httpSubscriptionsOnlyWithToggleAndNeverWithDeviceData() {
        val plain = java.net.URL("http://panel.example.invalid/sub")
        val secure = java.net.URL("https://panel.example.invalid/sub")
        assertFalse(SubscriptionRequestPolicy.allowed(plain, false))
        assertTrue(SubscriptionRequestPolicy.allowed(plain, true))
        assertThrows(IllegalArgumentException::class.java) { SubscriptionRequestPolicy.requireAllowed(plain, false) }
        SubscriptionRequestPolicy.requireAllowed(plain, true)
        assertThrows(IllegalArgumentException::class.java) { SubscriptionRequestPolicy.requireAllowed(java.net.URL("ftp://x.example.invalid/"), true) }
        assertThrows(IllegalArgumentException::class.java) { SubscriptionRequestPolicy.redirect(secure, "http://panel.example.invalid/x") }
        assertEquals("http", SubscriptionRequestPolicy.redirect(secure, "http://panel.example.invalid/x", true).protocol)
        assertFalse(SubscriptionRequestPolicy.deviceHeadersFor(plain, true))
        assertTrue(SubscriptionRequestPolicy.deviceHeadersFor(secure, true))
        assertFalse(Settings().allowHttpSubscriptions)
        assertTrue(Settings.from(Settings(allowHttpSubscriptions = true).toJson()).allowHttpSubscriptions)
        assertFalse(Settings.from(org.json.JSONObject()).allowHttpSubscriptions)
    }

    private val tuicLink = "tuic://11111111-2222-3333-4444-555555555555:secret@tuic.example.invalid:8443?sni=cdn.example.invalid&congestion_control=cubic&alpn=h3,spdy/3.1#%F0%9F%87%A9%F0%9F%87%AA%20TUIC"
    private val hy2Insecure = "hy2://pass:word@hy.example.invalid:443?insecure=1&obfs=salamander&obfs-password=mask&mport=20000-20010,443#HY"

    @Test fun tuicGoesToSingBoxWithAllFields() {
        val s = LinkParser.parse(tuicLink)
        assertEquals(Server.ENGINE_SINGBOX, s.engine)
        assertEquals("tuic", s.proto); assertEquals(8443, s.port); assertEquals("DE", s.countryCode)
        val ob = JSONObject(s.outbound)
        assertEquals("tuic", ob.getString("type"))
        assertEquals("11111111-2222-3333-4444-555555555555", ob.getString("uuid"))
        assertEquals("secret", ob.getString("password"))
        assertEquals("cubic", ob.getString("congestion_control"))
        assertEquals("cdn.example.invalid", ob.getJSONObject("tls").getString("server_name"))
        assertEquals(2, ob.getJSONObject("tls").getJSONArray("alpn").length())
        assertThrows(Exception::class.java) { LinkParser.parse("tuic://@h.example.invalid:1#x") }
    }

    @Test fun hysteriaOnlyUsesSingBoxWhenXrayCannot() {
        val plain = LinkParser.parse("hy2://pw@hy.example.invalid:443?obfs=salamander&obfs-password=m#A")
        assertEquals(Server.ENGINE_XRAY, plain.engine)
        val s = LinkParser.parse(hy2Insecure)
        assertEquals(Server.ENGINE_SINGBOX, s.engine)
        val ob = JSONObject(s.outbound)
        assertEquals("pass:word", ob.getString("password"))
        assertTrue(ob.getJSONObject("tls").getBoolean("insecure"))
        assertEquals("salamander", ob.getJSONObject("obfs").getString("type"))
        assertEquals(listOf("20000:20010", "443:443"), ob.getJSONArray("server_ports").let { a -> (0 until a.length()).map(a::getString) })
        assertThrows(Exception::class.java) { LinkParser.parse("hy2://pw@h.example.invalid:443?insecure=1&mport=1-99999#x") }
    }

    @Test fun engineSurvivesStorageAndOldProfilesStayXray() {
        val s = LinkParser.parse(tuicLink)
        assertEquals(s, Server.from(s.toJson()))
        val old = s.toJson().apply { remove("engine") }
        assertEquals(Server.ENGINE_XRAY, Server.from(old).engine)
    }

    @Test fun xrayReachesSingBoxServersThroughLocalSocks() {
        val tuic = LinkParser.parse(tuicLink)
        val hy = LinkParser.parse(hy2Insecure)
        val vless = LinkParser.parse("vless://11111111-2222-3333-4444-555555555555@v.example.invalid:443?security=tls&type=ws#V")
        val servers = listOf(vless, tuic, hy)
        val cfg = JSONObject(ConfigBuilder.build(servers, 1, Settings(fragment = true, mux = true), null))
        val out = cfg.getJSONArray("outbounds")
        fun tag(t: String) = (0 until out.length()).map { out.getJSONObject(it) }.first { it.optString("tag") == t }
        for ((tagName, port) in listOf("p1" to 20000, "p2" to 20001)) {
            val ob = tag(tagName)
            assertEquals("socks", ob.getString("protocol"))
            assertFalse(ob.has("mux")); assertFalse(ob.has("streamSettings"))
            assertEquals(port, ob.getJSONObject("settings").getJSONArray("servers").getJSONObject(0).getInt("port"))
        }
        val probe = JSONObject(ConfigBuilder.probe(tuic, 22000)).getJSONArray("outbounds").getJSONObject(0)
        assertEquals(22000, probe.getJSONObject("settings").getJSONArray("servers").getJSONObject(0).getInt("port"))
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.probe(tuic) }
        // Цепочка через sing-box-сервер не поддерживается и не включается молча.
        assertFalse(ChainPolicy.supports(tuic))
        assertThrows(IllegalArgumentException::class.java) {
            ConfigBuilder.build(listOf(tuic), 0, Settings(chainServerId = vless.id), null, chain = vless)
        }
    }

    @Test fun helperConfigMapsEachServerAndRejectsUnsafeInput() {
        val tuic = LinkParser.parse(tuicLink)
        val hy = LinkParser.parse(hy2Insecure)
        val vless = LinkParser.parse("vless://11111111-2222-3333-4444-555555555555@v.example.invalid:443?security=tls#V")
        assertNull(SingBoxHelper.config(listOf(vless), 20000, "1.1.1.1"))
        val text = SingBoxHelper.config(listOf(vless, tuic, hy), 20000, "192.168.1.1")!!
        val cfg = JSONObject(text)
        assertEquals(20001, cfg.getJSONArray("inbounds").getJSONObject(1).getInt("listen_port"))
        assertEquals("127.0.0.1", cfg.getJSONArray("inbounds").getJSONObject(0).getString("listen"))
        assertEquals("net", cfg.getJSONObject("route").getString("default_domain_resolver"))
        assertFalse(cfg.getJSONObject("route").has("auto_detect_interface"))
        assertThrows(IllegalArgumentException::class.java) { SingBoxHelper.config(listOf(tuic), 20000, "dns.example") }
        val withFile = tuic.copy(outbound = JSONObject(tuic.outbound).apply { getJSONObject("tls").put("certificate_path", "/sdcard/x") }.toString())
        assertThrows(IllegalArgumentException::class.java) { SingBoxHelper.config(listOf(withFile), 20000, "1.1.1.1") }
        val detour = tuic.copy(outbound = JSONObject(tuic.outbound).put("detour", "direct").toString())
        assertThrows(IllegalArgumentException::class.java) { SingBoxHelper.config(listOf(detour), 20000, "1.1.1.1") }
        val wrongType = tuic.copy(outbound = JSONObject(tuic.outbound).put("type", "socks").toString())
        assertThrows(IllegalArgumentException::class.java) { SingBoxHelper.config(listOf(wrongType), 20000, "1.1.1.1") }
        assertTrue(AddressPolicy.isIpLiteral("77.88.8.8")); assertFalse(AddressPolicy.isIpLiteral("1.1.1.1.1"))
        // Проверка настоящим sing-box (scripts: TUTUN_SINGBOX_FIXTURE=путь → sing-box check -c путь).
        System.getenv("TUTUN_SINGBOX_FIXTURE")?.let { java.io.File(it).writeText(text) }
    }
}
