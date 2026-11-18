package app.tutun

import org.junit.Assert.*
import org.junit.Test

class ParityTests {
    @Test fun chainDoesNotSilentlyReplaceAnUnsupportedManualTarget() {
        val tcp = server("tcp", "🇫🇮 TCP")
        val udp = server("udp", "🇩🇪 UDP").copy(outbound = """{"protocol":"hysteria","settings":{}}""")
        val first = server("first", "First")
        val s = Settings(chainServerId = first.id)
        assertTrue(ChainPolicy.targets(listOf(tcp,udp,first), Selection("server","udp"), s).isEmpty())
        assertTrue(ChainPolicy.targets(listOf(tcp,udp,first), Selection("country","DE"), s).isEmpty())
        assertEquals(listOf(tcp), ChainPolicy.targets(listOf(tcp,udp,first), Selection(), s))
    }
    @Test fun chainUsesFirstHopWithoutLoopAndFragmentStaysOnFirstHop() {
        val first = server("first", "First")
        val target = server("target", "Target")
        val settings = Settings(chainServerId = first.id, fragment = true)
        val config = org.json.JSONObject(ConfigBuilder.build(listOf(target), 0, settings, null, chain = first))
        val out = config.getJSONArray("outbounds")
        assertEquals("chain", out.getJSONObject(0).getJSONObject("streamSettings").getJSONObject("sockopt").getString("dialerProxy"))
        val hop = (0 until out.length()).map { out.getJSONObject(it) }.first { it.optString("tag") == "chain" }
        assertEquals("fragment", hop.getJSONObject("streamSettings").getJSONObject("sockopt").getString("dialerProxy"))
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.build(listOf(first), 0, settings, null, chain = first) }
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.build(listOf(target), 0, settings, null) }
        assertEquals(first.id, Settings.from(settings.toJson()).chainServerId)
        assertFalse(ChainPolicy.supports(first.copy(outbound = """{"protocol":"hysteria","settings":{}}""")))
        System.getenv("TUTUN_CHAIN_FIXTURE")?.let { path ->
            java.io.File(path).writeText(ConfigBuilder.build(listOf(target), 0, settings.copy(russiaDirect = false), null, withTun = false, chain = first))
        }
    }

    @Test fun externalLinksOnlyOpenSupportedImportPreview() {
        assertTrue(ImportLinkPolicy.accepts("vless://fixture@example.invalid:443"))
        assertTrue(ImportLinkPolicy.accepts("happ://routing/add/fixture"))
        listOf("file:///data/private", "https://example.invalid", "tutun://connect", "tuic://fixture", "vless://" + "x".repeat(1_048_577)).forEach { assertFalse(ImportLinkPolicy.accepts(it)) }
    }

    @Test fun draftDoesNotLeakIntoBackgroundSaveOrMetadata() {
        val preferences = DraftSettings(); var persisted = Settings()
        preferences.edit { it.copy(remoteDNS = "9.9.9.9", blockAds = true) }
        preferences.immediate({ it.copy(language = "ja", favorites = listOf("s:b")) }) { persisted = it; true }
        assertEquals("1.1.1.1", persisted.remoteDNS); assertFalse(persisted.blockAds)
        assertEquals("ja", persisted.language); assertEquals("ja", preferences.draft.value.language)
        assertEquals("9.9.9.9", preferences.draft.value.remoteDNS); assertTrue(preferences.dirty)
        preferences.accept { persisted = it; true }
        assertTrue(persisted.blockAds); assertFalse(preferences.dirty)
    }
    @Test fun failedSaveDoesNotReplaceAcceptedSettings() {
        val preferences = DraftSettings(); preferences.edit { it.copy(blockAds = true) }
        assertFalse(preferences.accept { false }); assertFalse(preferences.accepted.value.blockAds); assertTrue(preferences.dirty)
        assertFalse(preferences.immediate({ it.copy(language = "ja") }) { false }); assertEquals("system", preferences.accepted.value.language)
    }
    @Test fun discardRestoresAcceptedAndKeepsImmediateMetadata() {
        val preferences = DraftSettings(); preferences.edit { it.copy(blockAds = true) }
        preferences.immediate({ it.copy(language = "uk") }) { true }
        preferences.load(preferences.accepted.value)
        assertFalse(preferences.draft.value.blockAds); assertEquals("uk", preferences.draft.value.language)
    }
    private fun server(id: String, name: String) = Server(id, name, "socks", "example.invalid", 443, "tcp", """{"protocol":"socks","settings":{"servers":[{"address":"example.invalid","port":443}]}}""")
    private val a = server("a", "🇫🇮 Alpha")
    private val b = server("b", "🇫🇮 Beta")
    private val c = server("c", "🇩🇪 Gamma")
    private val all = listOf(a,b,c)
    private val pings = mapOf("a" to 80, "b" to 150, "c" to 20)
    @Test fun globalFastestIgnoresFavorites() {
        val selected = CountrySelector.candidates(all, Selection(), Settings(favorites = listOf("s:b")), pings)
        assertEquals("c", selected.first().id)
    }
    @Test fun countryFavoritesDoNotCaptureOtherCountries() {
        val selected = CountrySelector.candidates(all, Selection("country","FI"), Settings(favorites = listOf("s:b")), pings)
        assertEquals(listOf("b"), selected.map { it.id })
    }
    @Test fun countryLastUsedKeepsSameCountryBackup() {
        val selected = CountrySelector.candidates(all, Selection("country","FI"), Settings(countryPick = "lastUsed", lastServerByCountry = mapOf("FI" to "b")), pings)
        assertEquals(listOf("b","a"), selected.map { it.id })
    }
    @Test fun firstRandomAndBackupOff() {
        assertEquals(listOf("a"), CountrySelector.candidates(all, Selection("country","FI"), Settings(countryPick = "first", failover = false), pings).map { it.id })
        assertEquals("b", CountrySelector.candidates(all, Selection("country","FI"), Settings(countryPick = "random"), pings) { it.last() }.first().id)
    }
    @Test fun otherCountriesGroupDoesNotFallBackToAll() {
        val unlabelled = server("x","Unlabelled")
        assertEquals("x", CountrySelector.candidates(all + unlabelled, Selection("country","??"), Settings(), pings).first().id)
    }
    @Test fun importedConfigurationCannotReadLocalCertificateFilesOrSockets() {
        val file = a.copy(outbound = """{"protocol":"socks","streamSettings":{"tlsSettings":{"certificates":[{"certificateFile":"/data/private"}]}}}""")
        val socket = a.copy(outbound = """{"protocol":"socks","settings":{"servers":[{"address":"unix:/data/private","port":443}]}}""")
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.probe(file) }
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.build(listOf(socket), 0, Settings(), null) }
        assertThrows(IllegalArgumentException::class.java) { ConfigBuilder.build(listOf(a), 0, Settings(directSites = listOf("ext:private.dat:list")), null) }
        ConfigBuilder.build(listOf(a), 0, Settings(), null)
    }
    @Test fun invalidHealthParametersAreRejectedBeforeCoreStart() {
        assertThrows(IllegalArgumentException::class.java) { ConnectionValidation.settings(Settings(testURL = "file:///data/private")) }
        assertThrows(IllegalArgumentException::class.java) { ConnectionValidation.settings(Settings(probeIntervalSec = 0)) }
    }
    @Test fun subscriptionQrCanBeDecodedIncludingUtf8() {
        val value = "https://example.invalid/sub?name=тест&key=fixture"
        val matrix = SubscriptionQr.matrix(value)
        val source = object : com.google.zxing.LuminanceSource(matrix.width, matrix.height) {
            override fun getRow(y: Int, row: ByteArray?): ByteArray = ByteArray(width) { x -> if (matrix[x,y]) 0 else 255.toByte() }
            override fun getMatrix(): ByteArray = ByteArray(width * height) { i -> if (matrix[i % width,i / width]) 0 else 255.toByte() }
        }
        val decoded = com.google.zxing.qrcode.QRCodeReader().decode(com.google.zxing.BinaryBitmap(com.google.zxing.common.HybridBinarizer(source)))
        assertEquals(value, decoded.text)
    }
    @Test fun privateAddressesAreLiteralCidrsInsteadOfHostnamePrefixes() {
        listOf("10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1", "127.0.0.1", "::1", "fd12::1", "fe80::1").forEach { assertTrue(it, AddressPolicy.isPrivate(it)) }
        listOf("10.evil.example", "192.168.example", "172.32.0.1", "8.8.8.8", "10.999.0.1", "2001:4860:4860::8888").forEach { assertFalse(it, AddressPolicy.isPrivate(it)) }
    }
    @Test fun paritySettingsAndSubscriptionMetadataSurviveUpgrade() {
        val s = Settings(language = "uk", countryPick = "lastUsed", countryPreferFavorites = false, failover = false, lastServerByCountry = mapOf("FI" to "a"))
        assertEquals(s, Settings.from(s.toJson()))
        val sub = Subscription("id", "https://example.invalid", updateIntervalHours = 72, enabled = false, announce = "Test", collapsed = true)
        assertEquals(sub, Subscription.from(sub.toJson()))
    }
    @Test fun translationReadsAreObservableByComposeIncludingLazyItems() {
        val previous = L10n.language.value
        try {
            L10n.select("en")
            var reads = 0
            androidx.compose.runtime.snapshots.Snapshot.observe({ reads++ }, null) { tr("Настройки"); L10n.locale }
            assertTrue("Lazy content must observe the locale, not only read StateFlow.value", reads > 0)
            L10n.select("ja"); assertEquals("ja", L10n.current)
        } finally { L10n.select(previous) }
    }
    @Test fun languageFallbackUsesSystemOrderAndNeverUnsupportedLocale() {
        assertEquals("en", L10n.resolve("system", listOf("zz")))
        assertEquals("uk", L10n.resolve("system", listOf("zz","uk","en")))
        assertEquals("ja", L10n.resolve("ja", listOf("ru")))
        assertEquals(21, L10n.languages.size)
    }
}
