package app.tutun

import android.content.Context
import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import libv2ray.Libv2ray
import java.io.File
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import javax.net.ssl.HttpsURLConnection

object GeoUpdates {
    data class Status(val stage: String, val file: String = "", val bytes: Long = 0, val total: Long = -1)
    val progress = MutableStateFlow<Status?>(null)
    val error = MutableStateFlow<String?>(null)
    val updated = MutableStateFlow(0L)
    private val names = listOf("geoip.dat", "geosite.dat")
    private const val source = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/"
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("geo-updates", Context.MODE_PRIVATE)
    private var running = false
    private var loaded: String? = null

    @Synchronized fun prepareCore(ctx: Context) {
        val id = prefs(ctx).getString("current", null)
        val dir = id?.let { File(ctx.filesDir, it) } ?: ctx.filesDir
        Libv2ray.initCoreEnv(dir.absolutePath, "")
        loaded = id
        updated.value = prefs(ctx).getLong("time", 0)
    }

    @Synchronized fun start(ctx: Context) {
        if (running) return
        running = true
        error.value = null
        progress.value = Status("download", names.first())
        val proxy = if (VpnState.status.value.isActive) Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", ConfigBuilder.SOCKS_PORT)) else Proxy.NO_PROXY
        TutunApp.scope.launch(Dispatchers.IO) {
            val dir = File(ctx.filesDir, "geo-" + UUID.randomUUID())
            try {
                synchronized(this@GeoUpdates) {
                    val keep = setOf(loaded, prefs(ctx).getString("current", null))
                    ctx.filesDir.listFiles()?.filter { it.isDirectory && it.name.startsWith("geo-") && it.name !in keep }?.forEach { it.deleteRecursively() }
                }
                check(dir.mkdir())
                for (name in names) {
                    val digest = MessageDigest.getInstance("SHA-256")
                    progress.value = Status("download", name)
                    fetch(name, proxy) { conn ->
                        val total = conn.contentLengthLong
                        var count = 0L
                        conn.inputStream.use { input -> File(dir, name).outputStream().use { out ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                count += n
                                require(count <= 256L * 1024 * 1024)
                                out.write(buffer, 0, n)
                                digest.update(buffer, 0, n)
                                progress.value = Status("download", name, count, total)
                            }
                            out.fd.sync()
                        } }
                        check(count > 100_000 && (total < 0 || count == total)) { "$name: incomplete" }
                    }
                    progress.value = Status("verify", name)
                    val expected = fetch("$name.sha256sum", proxy) { conn ->
                        conn.inputStream.buffered().use { input ->
                            val bytes = ByteArray(64)
                            java.io.DataInputStream(input).readFully(bytes)
                            String(bytes, Charsets.US_ASCII)
                        }
                    }
                    check(digest.digest().joinToString("") { "%02x".format(it) }.equals(expected, true)) { "$name: SHA-256" }
                }
                progress.value = Status("install")
                val now = System.currentTimeMillis()
                check(prefs(ctx).edit().putString("current", dir.name).putLong("time", now).commit())
                updated.value = now
            } catch (e: Exception) {
                dir.deleteRecursively()
                error.value = e.localizedMessage ?: e.javaClass.simpleName
            } finally {
                synchronized(this@GeoUpdates) { progress.value = null; running = false }
            }
        }
    }

    private fun <T> fetch(name: String, proxy: Proxy, read: (HttpsURLConnection) -> T): T {
        val conn = URL(source + name).openConnection(proxy) as HttpsURLConnection
        try {
            conn.connectTimeout = 15000
            conn.readTimeout = 30000
            conn.setRequestProperty("Accept-Encoding", "identity")
            check(conn.responseCode == 200) { "$name: HTTP ${conn.responseCode}" }
            return read(conn)
        } finally { conn.disconnect() }
    }
}

@Composable
fun GeoUpdateCard() {
    val ctx = LocalContext.current.applicationContext
    val p by GeoUpdates.progress.collectAsState()
    val updated by GeoUpdates.updated.collectAsState()
    val error by GeoUpdates.error.collectAsState()
    val settings by Repo.settings.collectAsState()
    Card {
        SwitchRow(tr("Обновлять раз в неделю"), settings.geoAutoUpdate) { v -> Repo.updateSettings { it.copy(geoAutoUpdate = v) } }
        Text(tr("Обновлены") + " · " + if (updated > 0) java.text.DateFormat.getDateTimeInstance().format(java.util.Date(updated)) else tr("ещё нет"))
        Button(enabled = p == null, onClick = { GeoUpdates.start(ctx) }) { Text(tr("Обновить сейчас")) }
        p?.let { s ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val fraction = if (s.total > 0) (s.bytes.toFloat() / s.total).coerceIn(0f, 1f) else null
                if (fraction == null) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else CircularProgressIndicator(progress = { fraction }, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                Text(when (s.stage) {
                    "verify" -> tr("Проверяю…") + " " + s.file
                    "install" -> tr("Устанавливаю базы…")
                    else -> listOfNotNull(tr("Загрузка"), s.file, Formatter.formatShortFileSize(ctx, s.bytes), fraction?.let { "${(it * 100).toInt()}%" }).joinToString(" · ")
                })
            }
        }
        error?.let { Text(it, color = C.bad) }
    }
}
