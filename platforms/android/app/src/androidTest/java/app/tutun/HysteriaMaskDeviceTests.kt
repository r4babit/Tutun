package app.tutun

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import libv2ray.Libv2ray
import libv2ray.CoreCallbackHandler
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class HysteriaMaskDeviceTests {
    @Test fun embeddedCoreAcceptsSalamanderAndRejectsUnknownMaskWithoutNetworkTraffic() {
        val profile = LinkParser.parse("hysteria2://fixture@127.0.0.1:9?obfs=salamander&obfs-password=fixture&sni=fixture.invalid")
        val config = JSONObject(ConfigBuilder.probe(profile))
        fun controller() = Libv2ray.newCoreController(object : CoreCallbackHandler {
            override fun startup(): Long = 0
            override fun shutdown(): Long = 0
            override fun onEmitStatus(code: Long, message: String?): Long = 0
        })
        val good = controller()
        try { good.startLoop(config.toString(), -1); assertTrue(good.isRunning) }
        finally { runCatching { good.stopLoop() } }
        config.getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings").getJSONObject("finalmask").getJSONArray("udp").getJSONObject(0).put("type", "unknown-fixture-mask")
        val bad = controller()
        try { assertThrows(Exception::class.java) { bad.startLoop(config.toString(), -1) } }
        finally { runCatching { bad.stopLoop() } }
        assertThrows(LinkException::class.java) { LinkParser.parse("hysteria2://fixture@127.0.0.1:9?obfs=salamander") }
    }
}
