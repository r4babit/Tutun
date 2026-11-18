package app.tutun

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.net.URL
import javax.crypto.KeyGenerator

class ReliabilityTests {
    @Test fun oldConsentNeverSilentlyEnablesDeviceHeaders() {
        val old = Settings.from(JSONObject().put("sendHWID", true))
        assertFalse(old.sendHWID); assertEquals(0, old.hwidConsentVersion)
        assertFalse(SubscriptionRequestPolicy.sendDeviceHeaders(old))
    }
    @Test fun explicitConsentSurvivesRoundtrip() {
        val s = Settings(sendHWID = true, hwidConsentVersion = 1)
        assertTrue(SubscriptionRequestPolicy.sendDeviceHeaders(Settings.from(s.toJson())))
    }
    @Test fun explicitRefusalSurvivesRoundtrip() {
        val s = Settings(hwidConsentVersion = 1)
        assertFalse(SubscriptionRequestPolicy.sendDeviceHeaders(Settings.from(s.toJson())))
    }
    @Test fun settingsThatAffectLiveHealthAlsoRequireApply() {
        val s = Settings()
        assertTrue(s.requiresReconnect(s.copy(probeIntervalSec = 60)))
        assertTrue(s.requiresReconnect(s.copy(failLimit = 5)))
        assertTrue(s.requiresReconnect(s.copy(directSites = listOf("example.org"))))
    }
    @Test fun metadataChangesDoNotRequireReconnection() {
        val s = Settings()
        assertFalse(s.requiresReconnect(s.copy(favorites = listOf("c:NL"), hwidConsentVersion = 1, sendHWID = true,
            updateOnLaunch = false, connectOnBoot = true)))
    }
    @Test fun stoppingInvalidatesOldProbeAndQueuedRecovery() {
        val gate = VpnSessionGate(); val started = gate.start(); val recovering = gate.recover()!!
        assertFalse(gate.accepts(started)); val stopped = gate.stop()
        assertFalse(gate.accepts(recovering)); assertTrue(gate.matches(stopped)); assertNull(gate.recover())
    }
    @Test fun newUserStartWinsOverOldStopAndOldProbe() {
        val gate = VpnSessionGate(); val old = gate.start(); val stop = gate.stop(); val fresh = gate.start()
        assertFalse(gate.accepts(old)); assertFalse(gate.matches(stop)); assertTrue(gate.accepts(fresh))
    }
    @Test fun networkBurstsInvalidateEarlierRecoveryTickets() {
        val gate = VpnSessionGate(); gate.start(); val one = gate.recover()!!; val two = gate.recover()!!
        assertFalse(gate.accepts(one)); assertTrue(gate.accepts(two))
    }
    @Test fun emptyIncludeListIsRejectedInsteadOfTunnelingEverything() {
        assertThrows(IllegalArgumentException::class.java) { VpnAppPolicy.rules("include", emptyList(), "app.tutun") { true } }
    }
    @Test fun removedOrOwnAppsDoNotMakeIncludeListGlobal() {
        assertThrows(IllegalArgumentException::class.java) {
            VpnAppPolicy.rules("include", listOf("app.tutun", "uninstalled"), "app.tutun") { it != "uninstalled" }
        }
    }
    @Test fun includeAndExcludeListsStaySeparate() {
        val include = VpnAppPolicy.rules("include", listOf("browser", "browser"), "app.tutun") { true }
        assertEquals(listOf("browser"), include.allowed); assertTrue(include.excluded.isEmpty())
        val exclude = VpnAppPolicy.rules("exclude", listOf("bank"), "app.tutun") { true }
        assertNull(exclude.allowed); assertEquals(listOf("bank", "app.tutun"), exclude.excluded)
    }
    @Test fun redirectsUseHttpsAndCredentialsStayOnSameOrigin() {
        val initial = URL("https://provider.example/sub")
        assertTrue(SubscriptionRequestPolicy.sameOrigin(initial, URL("https://PROVIDER.example:443/next")))
        assertFalse(SubscriptionRequestPolicy.sameOrigin(initial, URL("https://cdn.example/next")))
        assertFalse(SubscriptionRequestPolicy.sameOrigin(initial, URL("https://provider.example:8443/next")))
        assertEquals("https://provider.example/next", SubscriptionRequestPolicy.redirect(initial, "/next").toString())
        assertThrows(IllegalArgumentException::class.java) { SubscriptionRequestPolicy.redirect(initial, "http://provider.example/plain") }
    }
    private fun key() = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    @Test fun encryptedStateRoundtripsWithoutPlaintext() {
        val secret = "https://example.invalid/private-subscription-key".toByteArray()
        val key = key(); val blob = StateCipher.encrypt(secret, key)
        assertArrayEquals(secret, StateCipher.decrypt(blob, key))
        assertFalse(String(blob).contains("private-subscription-key"))
        assertFalse(blob.contentEquals(StateCipher.encrypt(secret, key)))
    }
    @Test fun tamperingAndWrongKeyAreRejected() {
        val key = key(); val blob = StateCipher.encrypt("profile".toByteArray(), key)
        assertThrows(Exception::class.java) { StateCipher.decrypt(blob, key()) }
        blob[blob.lastIndex] = (blob.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { StateCipher.decrypt(blob, key) }
    }
    @Test fun corruptHeaderAndTruncationAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { StateCipher.decrypt(byteArrayOf(1, 2, 3), key()) }
        val blob = StateCipher.encrypt("profile".toByteArray(), key()); blob[0] = 0
        assertThrows(IllegalArgumentException::class.java) { StateCipher.decrypt(blob, key()) }
    }
    @Test fun changingServerUpdatesRoutingTargetButLeavesLocalProxyOnLoopback() {
        val outbound = """{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":9}]}}"""
        val servers = listOf(Server("a", "A", "socks", "127.0.0.1", 9, "tcp", outbound), Server("b", "B", "socks", "127.0.0.1", 9, "tcp", outbound))
        val json = JSONObject(ConfigBuilder.build(servers, 1, Settings(), null))
        val inbounds = json.getJSONArray("inbounds")
        for (i in 1 until inbounds.length()) assertEquals("127.0.0.1", inbounds.getJSONObject(i).getString("listen"))
        val rules = json.getJSONObject("routing").getJSONArray("rules")
        assertEquals("p1", rules.getJSONObject(rules.length() - 1).getString("outboundTag"))
    }
}
