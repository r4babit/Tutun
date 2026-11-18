package app.tutun

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Вспомогательный sing-box, как helper на маке: держит серверы, которые xray не умеет (TUIC,
 * Hysteria2 с insecure/портами). Для k-го такого сервера открывает SOCKS 127.0.0.1:base+k,
 * а xray ходит в него обычным socks-outbound. Процесс запускается от UID приложения, поэтому,
 * как и само ядро xray, выходит в сеть мимо VPN.
 *
 * Бинарник лежит в APK как lib/<abi>/libsingbox.so (иначе Android не даст его запустить);
 * сборка — scripts/build-singbox-android.sh.
 */
object SingBoxHelper {
    const val BASE_PORT = 20000
    const val PROBE_BASE_PORT = 22000
    const val MAX_SERVERS = 900

    private var binary: File? = null
    private var workRoot: File? = null

    fun init(context: Context) {
        binary = File(context.applicationInfo.nativeLibraryDir, "libsingbox.so").takeIf { it.canExecute() }
        workRoot = File(context.noBackupFilesDir, "singbox").apply { mkdirs() }
    }

    /** Есть ли sing-box для процессора этого телефона. */
    val supported: Boolean get() = binary != null

    /** Конфиг: socks-вход h{k} на base+k → сервер o{k}. null, если серверов sing-box нет. */
    fun config(servers: List<Server>, basePort: Int, dnsServer: String): String? {
        val hs = servers.filter { it.usesSingBox }
        if (hs.isEmpty()) return null
        require(hs.size <= MAX_SERVERS) { "Слишком много серверов TUIC/Hysteria2" }
        require(AddressPolicy.isIpLiteral(dnsServer)) { "DNS для sing-box должен быть IP-адресом" }
        val inbounds = JSONArray(); val outbounds = JSONArray(); val rules = JSONArray()
        hs.forEachIndexed { k, s ->
            ConnectionValidation.server(s)
            inbounds.put(JSONObject().put("type", "socks").put("tag", "h$k").put("listen", "127.0.0.1").put("listen_port", basePort + k))
            outbounds.put(JSONObject(s.outbound).put("tag", "o$k"))
            rules.put(JSONObject().put("inbound", JSONArray().put("h$k")).put("outbound", "o$k"))
        }
        outbounds.put(JSONObject().put("type", "direct").put("tag", "direct"))
        return JSONObject()
            .put("log", JSONObject().put("level", "warn"))
            // Системного resolv.conf на Android нет — адреса серверов разрешаем DNS текущей сети.
            .put("dns", JSONObject().put("servers", JSONArray().put(JSONObject().put("type", "udp").put("tag", "net").put("server", dnsServer))))
            .put("inbounds", inbounds)
            .put("outbounds", outbounds)
            .put("route", JSONObject().put("rules", rules).put("final", "direct").put("default_domain_resolver", "net"))
            .toString()
    }

    /** Номер socks-порта для сервера среди серверов sing-box из списка. */
    fun portFor(servers: List<Server>, server: Server, basePort: Int): Int {
        val k = servers.filter { it.usesSingBox }.indexOfFirst { it.id == server.id }
        require(k >= 0) { "Сервер не найден" }
        return basePort + k
    }

    /** DNS физической сети (приложение исключено из VPN, поэтому видит её). Если не вышло — запасной IP из настроек. */
    fun dnsServer(cm: android.net.ConnectivityManager, network: android.net.Network?, fallback: String): String {
        val props = runCatching { cm.getLinkProperties(network ?: cm.activeNetwork) }.getOrNull()
        val sys = props?.dnsServers?.firstOrNull { it is java.net.Inet4Address }?.hostAddress
        return sys ?: fallback.takeIf { AddressPolicy.isIpLiteral(it) } ?: "77.88.8.8"
    }

    class Running internal constructor(private val process: Process, private val output: StringBuilder) {
        val alive: Boolean get() = process.isAlive
        fun waitForExit() { runCatching { process.waitFor() } }
        fun stop() {
            process.destroy()
            if (!process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) process.destroyForcibly()
        }
        internal fun tail(): String = synchronized(output) { output.toString() }
    }

    /**
     * Запускает sing-box и ждёт, пока откроются все socks-порты. Файл конфига (в нём ключи серверов)
     * удаляется сразу после старта. Вывод sing-box не пишется в logcat.
     */
    fun start(config: String, basePort: Int, count: Int, name: String): Running {
        val bin = binary ?: error("sing-box недоступен на этом устройстве")
        val dir = File(workRoot, name).apply { mkdirs() }
        val file = File(dir, "config.json")
        file.writeText(config)
        file.setReadable(false, false); file.setReadable(true, true)
        val process = try {
            ProcessBuilder(bin.absolutePath, "run", "-c", file.absolutePath, "-D", dir.absolutePath)
                .directory(dir).redirectErrorStream(true).start()
        } catch (e: Exception) { file.delete(); throw IllegalStateException("sing-box не запустился") }
        val output = StringBuilder()
        Thread({
            runCatching { process.inputStream.bufferedReader().forEachLine { line ->
                synchronized(output) { output.append(line).append('\n'); if (output.length > 4000) output.delete(0, output.length - 4000) }
            } }
        }, "Tutun-singbox-$name").apply { isDaemon = true }.start()
        val running = Running(process, output)
        try {
            val deadline = System.currentTimeMillis() + 8000
            for (k in 0 until count) {
                while (!listening(basePort + k)) {
                    check(process.isAlive) { "sing-box (TUIC/Hysteria2) не принял конфиг" }
                    check(System.currentTimeMillis() < deadline) { "sing-box (TUIC/Hysteria2) не ответил" }
                    Thread.sleep(50)
                }
            }
        } catch (e: Exception) { running.stop(); throw e } finally { file.delete() }
        return running
    }

    private fun listening(port: Int) = runCatching {
        Socket().use { it.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), 200) }; true
    }.getOrDefault(false)
}
