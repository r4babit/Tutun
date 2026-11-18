package app.tutun

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings.Secure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import libv2ray.Libv2ray
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

/** Страна: флаг, название и её серверы. */
data class Country(val code: String, val name: String, val flag: String, val servers: List<Server>)

/** Shared state; credentials are encrypted in noBackupFilesDir using Android Keystore. */
object Repo {
    val servers = MutableStateFlow<List<Server>>(emptyList())
    val subs = MutableStateFlow<List<Subscription>>(emptyList())
    private val preferences = DraftSettings()
    val settings = preferences.draft
    val appliedSettings = preferences.accepted
    private var connectionDirty = false
    val selection = MutableStateFlow(Selection())
    val pings = MutableStateFlow<Map<String, Int>>(emptyMap())   // id → мс, -1 — не ответил
    val pinging = MutableStateFlow(false)
    val profiles = MutableStateFlow<List<RoutingProfile>>(emptyList())
    /** Трафик через VPN по дням: «2026-11-07» → (отдано, получено). */
    val days = MutableStateFlow<Map<String, Pair<Long, Long>>>(emptyMap())
    val message = MutableStateFlow<String?>(null)
    /** Настройки поменяли при включённом VPN — нужно переподключить, чтобы они вступили в силу. */
    val needsApply = MutableStateFlow(false)

    private lateinit var storage: SecureStateStore
    private var storageReady = false
    var vpnRequested = false; private set
    val connectionRevision = java.util.concurrent.atomic.AtomicLong(0)
    private var startupRefreshStarted = false
    lateinit var hwid: String; private set

    @SuppressLint("HardwareIds")
    private lateinit var connectivity: android.net.ConnectivityManager
    fun init(ctx: Context) {
        connectivity = ctx.getSystemService(android.net.ConnectivityManager::class.java)
        storage = SecureStateStore(ctx)
        val androidId = Secure.getString(ctx.contentResolver, Secure.ANDROID_ID) ?: UUID.randomUUID().toString()
        hwid = MessageDigest.getInstance("SHA-256").digest(("tutun-" + androidId).toByteArray())
            .take(8).joinToString("") { "%02x".format(it) }
        load()
    }

    private fun load() {
        try {
            val saved = storage.read()
            if (saved == null) { storageReady = true; return }
            val o = JSONObject(saved)
            servers.value = o.optJSONArray("servers")?.mapObjects(Server::from) ?: emptyList()
            subs.value = o.optJSONArray("subs")?.mapObjects(Subscription::from) ?: emptyList()
            preferences.load(Settings.from(o.optJSONObject("settings")))
            selection.value = Selection.from(o.optJSONObject("selection"))
            profiles.value = o.optJSONArray("profiles")?.mapObjects(RoutingProfile::from) ?: emptyList()
            o.optJSONObject("days")?.let { d ->
                days.value = d.keys().asSequence().associateWith { k -> d.getJSONArray(k).let { it.getLong(0) to it.getLong(1) } }
            }
            val p = o.optJSONObject("pings")
            pings.value = p?.keys()?.asSequence()?.associateWith { p.getInt(it) } ?: emptyMap()
            vpnRequested = o.optBoolean("vpnRequested", false)
            storage.write(saved)
            storageReady = true
        } catch (e: Exception) {
            storageReady = false
            message.value = "Не удалось открыть защищённые данные. Они не перезаписаны. Перезапустите телефон и откройте Tutun после разблокировки."
        }
    }

    @Synchronized
    fun save(settingsOverride: Settings = appliedSettings.value): Boolean {
        if (!storageReady) return false
        val o = JSONObject().put("vpnRequested", vpnRequested)
            .put("servers", servers.value.toJsonArray { it.toJson() })
            .put("subs", subs.value.toJsonArray { it.toJson() })
            .put("settings", settingsOverride.toJson())
            .put("selection", selection.value.toJson())
            .put("pings", JSONObject(pings.value as Map<*, *>))
            .put("profiles", profiles.value.toJsonArray { it.toJson() })
            .put("days", JSONObject().also { o -> days.value.forEach { (k, v) -> o.put(k, JSONArray().put(v.first).put(v.second)) } })
        return try { storage.write(o.toString()); true }
        catch (e: Exception) { message.value = "Не удалось сохранить защищённые данные"; false }
    }

    @Synchronized fun setVpnRequested(value: Boolean): Boolean {
        val old = vpnRequested
        vpnRequested = value
        if (save()) return true
        vpnRequested = old
        return false
    }

    fun connectionChanged() {
        connectionRevision.incrementAndGet()
        if (VpnState.status.value.isActive) connectionDirty = true
        refreshNeedsApply()
    }

    suspend fun refreshOnLaunch() {
        if (!storageReady || startupRefreshStarted || appliedSettings.value.hwidConsentVersion < 1) return
        startupRefreshStarted = true
        if (appliedSettings.value.updateOnLaunch && subs.value.isNotEmpty()) {
            val now = System.currentTimeMillis() / 1000
            subs.value.filter { it.enabled && now - it.lastUpdate >= it.updateIntervalHours * 3600L }.forEach { updateSubscription(it) }
        }
        else if (servers.value.isNotEmpty()) pingAll()
    }

    // MARK: подписки

    /** Добавляет подписку (http-ссылку) или серверы из текста. */
    suspend fun addFromText(text: String) {
        val t = text.trim()
        LinkParser.parseRoutingLink(t)?.let { p ->
            profiles.value = profiles.value.filter { it.id != p.id } + p
            preferences.immediate({ it.copy(profileId = p.id) }, ::save)
            connectionChanged(); save()
            message.value = "Профиль маршрутов «${p.name}» добавлен и включён"
            return
        }
        if (t.startsWith("http://") || t.startsWith("https://")) {
            if (subs.value.any { it.url == t }) { message.value = "Эта подписка уже добавлена"; return }
            val sub = Subscription(UUID.randomUUID().toString(), t)
            subs.value = subs.value + sub
            updateSubscription(sub)
        } else {
            val batch = withContext(Dispatchers.Default) { LinkParser.parseBatch(t, null) }
            if (batch.servers.isEmpty()) {
                message.value = "Не нашёл серверов" + (batch.errors.firstOrNull()?.let { ": $it" } ?: "")
                return
            }
            if (batch.profiles.isNotEmpty()) profiles.value = profiles.value + batch.profiles
            val known = servers.value.map { it.id }.toSet()
            servers.value = servers.value + batch.servers.filter { it.id !in known }
            save()
            message.value = "Добавлено серверов: ${batch.servers.size}"
            pingAll()
        }
    }

    suspend fun updateAll() { subs.value.forEach { updateSubscription(it) } }

    suspend fun updateSubscription(sub: Subscription) {
        try {
            val (meta, batch) = withContext(Dispatchers.IO) { fetch(sub) }
            servers.value = servers.value.filter { it.subId != sub.id } + batch.servers
            // Профили маршрутов от провайдера заменяют прежние профили этой подписки.
            profiles.value = profiles.value.filter { it.subId != sub.id } + batch.profiles.map { it.copy(subId = sub.id) }
            if (batch.profiles.isNotEmpty() && appliedSettings.value.profileId == null) {
                preferences.immediate({ it.copy(profileId = batch.profiles.first().id) }, ::save)
            }
            subs.value = subs.value.map { if (it.id == sub.id) meta else it }
            connectionChanged()
            save()
            pingAll()
        } catch (e: Exception) {
            subs.value = subs.value.map { if (it.id == sub.id) it.copy(lastError = e.message) else it }
            save()
            message.value = "${sub.name}: ${e.message}"
        }
    }

    fun removeSubscription(sub: Subscription) {
        subs.value = subs.value.filter { it.id != sub.id }
        servers.value = servers.value.filter { it.subId != sub.id }
        profiles.value = profiles.value.filter { it.subId != sub.id }
        connectionChanged()
        save()
    }

    private fun fetch(sub: Subscription): Pair<Subscription, ParsedBatch> {
        val c = openSubscription(sub.url)
        try {
            val code = c.responseCode
            if (code !in 200..299) throw Exception("сервер подписки ответил ошибкой $code")
            if (c.getHeaderField("x-hwid-max-devices-reached") == "true")
                throw Exception("превышен лимит устройств. Удалите старое устройство в кабинете провайдера и обновите подписку.")
            if (c.getHeaderField("x-hwid-not-supported") == "true")
                throw Exception("провайдер не выдал серверы этому устройству (включите «Отправлять ID устройства»)")
            val data = c.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (output.size() <= 16 * 1024 * 1024) {
                    val count = input.read(buffer, 0, minOf(buffer.size, 16 * 1024 * 1024 + 1 - output.size()))
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray() }
            require(data.size <= 16 * 1024 * 1024) { "Профиль больше 16 МБ" }
            val body = data.toString(Charsets.UTF_8)
            var meta = sub.copy(lastUpdate = System.currentTimeMillis() / 1000, lastError = null,
                supportURL = c.getHeaderField("support-url"), webPageURL = c.getHeaderField("profile-web-page-url"),
                announce = c.getHeaderField("announce")?.let { LinkParser.base64Decode(it.removePrefix("base64:")) ?: it })
            c.getHeaderField("subscription-userinfo")?.split(";")?.forEach { part ->
                val kv = part.split("=", limit = 2).map { it.trim() }
                val n = kv.getOrNull(1)?.toLongOrNull() ?: return@forEach
                meta = when (kv[0]) {
                    "upload" -> meta.copy(upload = n); "download" -> meta.copy(download = n)
                    "total" -> meta.copy(total = n); "expire" -> meta.copy(expire = n); else -> meta
                }
            }
            c.getHeaderField("profile-title")?.let { t ->
                val title = if (t.startsWith("base64:")) LinkParser.base64Decode(t.drop(7)) ?: t else t
                if (title.isNotBlank() && (sub.name.isEmpty() || sub.name == "Подписка")) meta = meta.copy(name = title)
            }
            var batch = LinkParser.parseBatch(body, sub.id)
            // Профиль маршрутов может прийти заголовком «routing» (формат Happ).
            c.getHeaderField("routing")?.let { r ->
                (LinkParser.parseRoutingLink(r) ?: LinkParser.parseRoutingJSON(LinkParser.base64Decode(r) ?: r))?.let {
                    batch = batch.copy(profiles = batch.profiles + it)
                }
            }
            if (batch.servers.isEmpty()) throw Exception("в подписке нет поддерживаемых серверов" +
                (batch.errors.take(2).joinToString("; ").let { if (it.isEmpty()) "" else ": $it" }))
            return meta to batch
        } finally { c.disconnect() }
    }

    private fun openSubscription(address: String): HttpURLConnection {
        var url = URL(address)
        val allowHttp = appliedSettings.value.allowHttpSubscriptions
        SubscriptionRequestPolicy.requireAllowed(url, allowHttp)
        var deviceHeaders = SubscriptionRequestPolicy.sendDeviceHeaders(appliedSettings.value)
        repeat(6) {
            val c = url.openConnection() as HttpURLConnection
            c.connectTimeout = 20_000; c.readTimeout = 30_000; c.instanceFollowRedirects = false
            c.setRequestProperty("User-Agent", "Tutun/${BuildConfig.VERSION_NAME} (Android)")
            if (SubscriptionRequestPolicy.deviceHeadersFor(url, deviceHeaders)) {
                c.setRequestProperty("X-HWID", hwid)
                c.setRequestProperty("X-Device-OS", "Android")
                c.setRequestProperty("X-Ver-OS", Build.VERSION.RELEASE)
                c.setRequestProperty("X-Device-Model", "${Build.MANUFACTURER} ${Build.MODEL}")
                c.setRequestProperty("X-Device-Locale", java.util.Locale.getDefault().toLanguageTag())
            }
            try {
                if (c.responseCode !in listOf(301, 302, 303, 307, 308)) return c
                val location = c.getHeaderField("Location") ?: error("В перенаправлении подписки нет адреса")
                val next = SubscriptionRequestPolicy.redirect(url, location, allowHttp)
                deviceHeaders = deviceHeaders && SubscriptionRequestPolicy.sameOrigin(url, next)
                url = next
            } catch (e: Exception) { c.disconnect(); throw e }
            c.disconnect()
        }
        error("Слишком много перенаправлений подписки")
    }

    // MARK: замеры

    /** Настоящий запрос через каждый сервер (временное ядро xray внутри приложения, мимо VPN). */
    suspend fun pingAll() {
        if (pinging.value) return
        pinging.value = true
        try {
            val list = usable()
            val url = appliedSettings.value.testURL
            val sem = Semaphore(8)
            // Серверы TUIC/Hysteria2 замеряются через временный sing-box на своих портах (не мешает работающему VPN).
            val helperServers = list.filter { it.usesSingBox }
            val helper = if (helperServers.isEmpty()) null else withContext(Dispatchers.IO) {
                runCatching {
                    val dns = SingBoxHelper.dnsServer(connectivity, null, appliedSettings.value.directDNS)
                    SingBoxHelper.start(SingBoxHelper.config(helperServers, SingBoxHelper.PROBE_BASE_PORT, dns)!!,
                        SingBoxHelper.PROBE_BASE_PORT, helperServers.size, "probe")
                }.getOrNull()
            }
            val results = try {
                coroutineScope {
                    list.map { s ->
                        async(Dispatchers.IO) {
                            sem.withPermit {
                                val ms = try {
                                    val port = if (s.usesSingBox) helper?.let { SingBoxHelper.portFor(helperServers, s, SingBoxHelper.PROBE_BASE_PORT) } else null
                                    if (s.usesSingBox && port == null) -1
                                    else Libv2ray.measureOutboundDelay(ConfigBuilder.probe(s, port), url).toInt()
                                } catch (e: Exception) { -1 }
                                s.id to (if (ms <= 0) -1 else ms)
                            }
                        }
                    }.awaitAll()
                }
            } finally { helper?.let { h -> withContext(Dispatchers.IO + kotlinx.coroutines.NonCancellable) { h.stop() } } }
            pings.value = pings.value + results
            save()
        } finally { pinging.value = false }
    }

    // MARK: выбор

    fun usable(): List<Server> {
        val disabled = subs.value.filter { !it.enabled }.map { it.id }.toSet()
        return servers.value.filter { it.subId !in disabled && LinkParser.rejectReason(it) == null }
    }

    private fun byPing(list: List<Server>): List<Server> {
        val p = pings.value
        return list.sortedWith(compareBy({ (p[it.id] ?: Int.MAX_VALUE).let { v -> if (v < 0) Int.MAX_VALUE - 1 else v } }))
    }

    /** Кандидаты для подключения: первый — основной, остальные — запасные на случай обрыва. */
    fun candidates(): List<Server> {
        val settings = appliedSettings.value
        val pool = ChainPolicy.targets(usable(), selection.value, settings)
        return CountrySelector.candidates(pool, selection.value, settings, pings.value)
    }

    fun countries(list: List<Server>): List<Country> = list.groupBy { it.countryCode ?: "??" }.map { (code, ss) ->
        Country(code, if (code == "??") tr("Другие") else Server.countryName(code), ss.first().flag ?: "🌐", byPing(ss))
    }.sortedBy { it.name }

    fun select(sel: Selection) {
        selection.value = sel
        if (sel.kind == "server") servers.value.firstOrNull { it.id == sel.value }?.let { server ->
            server.countryCode?.let { code -> preferences.immediate({ it.copy(lastServerByCountry = it.lastServerByCountry + (code to server.id)) }, ::save) }
        }
        connectionChanged(); save()
    }

    fun chainServer(): Server? = appliedSettings.value.chainServerId?.let { id -> usable().firstOrNull { it.id == id && ChainPolicy.supports(it) } ?: error("Сервер цепочки недоступен") }

    fun activeProfile(): RoutingProfile? = appliedSettings.value.profileId?.let { id -> profiles.value.firstOrNull { it.id == id } }

    fun isFavorite(key: String) = key in appliedSettings.value.favorites
    fun toggleFavorite(key: String) {
        preferences.immediate({ it.copy(favorites = if (key in it.favorites) it.favorites - key else it.favorites + key) }, ::save)
        refreshNeedsApply()
    }

    fun discardDraft() { preferences.load(appliedSettings.value); refreshNeedsApply() }

    fun setLanguage(language: String) {
        if (preferences.immediate({ it.copy(language = language) }, ::save)) L10n.select(language)
        refreshNeedsApply()
    }
    fun chooseHWID(allow: Boolean) {
        preferences.immediate({ it.copy(sendHWID = allow, hwidConsentVersion = 1) }, ::save)
        refreshNeedsApply()
    }
    fun saveSubscription(sub: Subscription) {
        subs.value = subs.value.map { if (it.id == sub.id) it.copy(name = sub.name, enabled = sub.enabled, updateIntervalHours = sub.updateIntervalHours) else it }
        connectionChanged(); save()
    }
    fun toggleSubscription(id: String) {
        subs.value = subs.value.map { if (it.id == id) it.copy(collapsed = !it.collapsed) else it }
        save()
    }
    fun markConnectionApplied(revision: Long) {
        if (revision == connectionRevision.get()) connectionDirty = false
        refreshNeedsApply()
    }
    private fun refreshNeedsApply() { needsApply.value = preferences.dirty || connectionDirty }

    /** Прибавить трафик за сегодня (вызывается службой раз в секунду). */
    fun addTraffic(up: Long, down: Long) {
        if (up == 0L && down == 0L) return
        val key = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).format(java.util.Date())
        val cur = days.value[key] ?: (0L to 0L)
        days.value = (days.value + (key to (cur.first + up to cur.second + down)))
            .entries.sortedBy { it.key }.takeLast(62).associate { it.key to it.value }
    }

    fun updateSettings(f: (Settings) -> Settings) {
        preferences.edit(f)
        refreshNeedsApply()
    }
    fun applySettings(): Boolean {
        try { ConnectionValidation.settings(settings.value, settings.value.profileId?.let { id -> profiles.value.firstOrNull { it.id == id } }) }
        catch (e: Exception) { message.value = e.message; return false }
        if (settings.value.chainServerId != null && usable().none { it.id == settings.value.chainServerId && ChainPolicy.supports(it) }) {
            message.value = "Сервер цепочки недоступен"; return false
        }
        if (!preferences.accept(::save)) return false
        connectionRevision.incrementAndGet()
        connectionDirty = VpnState.status.value.isActive
        refreshNeedsApply()
        return true
    }

    fun selectionTitle(): String = when (selection.value.kind) {
        "country" -> selection.value.value?.let { Server.countryName(it) } ?: tr("Самый быстрый")
        "server" -> servers.value.firstOrNull { it.id == selection.value.value }?.cleanName ?: tr("Самый быстрый")
        else -> tr("Самый быстрый")
    }
}
