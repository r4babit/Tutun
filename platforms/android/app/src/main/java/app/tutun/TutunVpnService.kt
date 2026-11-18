package app.tutun

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.service.quicksettings.TileService
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL

enum class VpnStatus { STOPPED, STARTING, RUNNING, RECONNECTING, FAILED;
    val isActive get() = this == STARTING || this == RUNNING || this == RECONNECTING
}

object VpnState {
    val status = MutableStateFlow(VpnStatus.STOPPED)
    val server = MutableStateFlow<Server?>(null)
    val latencyMs = MutableStateFlow<Int?>(null)
    val since = MutableStateFlow<Long?>(null)
    val error = MutableStateFlow<String?>(null)
    val log = MutableStateFlow<List<String>>(emptyList())
    val speedDown = MutableStateFlow(0L)
    val speedUp = MutableStateFlow(0L)
    val sessionBytes = MutableStateFlow(0L)
    @Synchronized fun write(msg: String) {
        Log.i("Tutun", msg)
        val t = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.ROOT).format(java.util.Date())
        log.value = (log.value + "$t $msg").takeLast(200)
    }
}

/** Lifecycle work is serialized; network requests never hold the lifecycle mutex. */
class TutunVpnService : VpnService() {
    companion object {
        private const val ACTION_START = "app.tutun.START"
        private const val ACTION_STOP = "app.tutun.STOP"
        private const val CHANNEL = "vpn"
        // Native start/stop operations also stay ordered across old/new Service instances.
        private val nativeDispatcher = java.util.concurrent.Executors.newSingleThreadExecutor { task ->
            Thread(task, "Tutun-native").apply { isDaemon = true }
        }.asCoroutineDispatcher()
        fun start(ctx: Context) {
            try { ctx.startForegroundService(Intent(ctx, TutunVpnService::class.java).setAction(ACTION_START)) }
            catch (e: Exception) { Repo.message.value = "Android не разрешил фоновый запуск. Откройте Tutun и подключитесь из приложения." }
        }
        fun stop(ctx: Context) {
            try { ctx.startService(Intent(ctx, TutunVpnService::class.java).setAction(ACTION_STOP)) }
            catch (e: Exception) { Repo.message.value = "Откройте Tutun, чтобы отключить VPN" }
        }
    }
    private data class Session(val servers: List<Server>, val settings: Settings, val profile: RoutingProfile?, val revision: Long, val chain: Server?)
    private val scope = CoroutineScope(SupervisorJob() + nativeDispatcher)
    private val lock = Mutex()
    private val gate = VpnSessionGate()
    private val main = Handler(Looper.getMainLooper())
    private var core: CoreController? = null
    @Volatile private var helper: SingBoxHelper.Running? = null
    private var pfd: ParcelFileDescriptor? = null
    @Volatile private var session: Session? = null
    private var current = 0
    private var healthJob: Job? = null
    private var statsJob: Job? = null
    private var recoveryJob: Job? = null
    @Volatile private var destroyed = false
    private lateinit var cm: ConnectivityManager
    private val networks = mutableMapOf<Network, Pair<NetworkCapabilities?, LinkProperties?>>()
    private var fingerprint: String? = null
    @Volatile private var underlying: Network? = null
    private var lastWake = 0L
    private var callbackRegistered = false
    private val recoveryDeferral = RecoveryDeferral()
    private inner class PhysicalCallback : ConnectivityManager.NetworkCallback {
        constructor() : super()

        override fun onAvailable(network: Network) { main.post { if (destroyed || networkCallback !== this@PhysicalCallback) return@post; networks.putIfAbsent(network, null to null) } }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { main.post {
            if (destroyed || networkCallback !== this@PhysicalCallback) return@post
            networks[network] = capabilities to networks[network]?.second; updateNetwork()
        } }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) { main.post {
            if (destroyed || networkCallback !== this@PhysicalCallback) return@post
            networks[network] = networks[network]?.first to properties; updateNetwork()
        } }
        override fun onLost(network: Network) { main.post { if (destroyed || networkCallback !== this@PhysicalCallback) return@post; networks.remove(network); updateNetwork() } }
    }
    private var networkCallback: ConnectivityManager.NetworkCallback = PhysicalCallback()
    private fun refreshPhysicalCallback() {
        if (destroyed) return
        if (callbackRegistered) runCatching { cm.unregisterNetworkCallback(networkCallback) }
        networks.clear()
        networkCallback = PhysicalCallback()
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
        cm.registerNetworkCallback(request, networkCallback)
        callbackRegistered = true
    }
    private val wakeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val pm = getSystemService(PowerManager::class.java)
            if (intent?.action == PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED && pm.isDeviceIdleMode) return
            // SCREEN_ON and leaving Doze can arrive together. Rebuild old cached transports once.
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastWake < 5_000) return
            lastWake = now
            scheduleRecovery("Телефон вышел из сна")
        }
    }

    override fun onCreate() {
        super.onCreate()
        scope.launch { L10n.language.collect { if (VpnState.status.value.isActive) publish(VpnState.status.value) } }
        cm = getSystemService(ConnectivityManager::class.java)
        refreshPhysicalCallback()
        val filter = IntentFilter(Intent.ACTION_SCREEN_ON).apply { addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(wakeReceiver, filter, RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(wakeReceiver, filter)
    }

    private fun updateNetwork() {
        if (destroyed) return
        val entry = networks.entries.filter { it.value.first != null && it.value.second != null }
            .maxByOrNull { (_, pair) ->
                val caps = pair.first!!
                (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 100 else 0) +
                    (if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) 10 else 0)
            }
        val network = entry?.key
        val lp = entry?.value?.second
        val next = if (network == null) "offline" else "$network|${lp?.interfaceName}|${lp?.linkAddresses}|${lp?.dnsServers}|${lp?.routes}"
        underlying = network
        if (pfd != null) runCatching { setUnderlyingNetworks(network?.let { arrayOf(it) }) }
        val previous = fingerprint
        fingerprint = next
        if (previous != null && previous != next) scheduleRecovery("Изменилась сеть")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            val ticket = gate.stop()
            recoveryDeferral.cancel()
            cancelMonitoring()
            scope.launch { lock.withLock {
                if (!gate.matches(ticket)) return@withLock
                Repo.setVpnRequested(false)
                closeCore()
                session = null
                publish(VpnStatus.STOPPED)
                VpnState.write("Отключено пользователем")
                stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId)
            } }
            return START_NOT_STICKY
        }
        if (intent == null && !Repo.vpnRequested && !(Build.VERSION.SDK_INT >= 29 && isAlwaysOn)) {
            stopSelfResult(startId); return START_NOT_STICKY
        }
        val ticket = gate.start()
        recoveryDeferral.begin(ticket)
        cancelMonitoring()
        publish(VpnStatus.STARTING)
        VpnState.error.value = null
        scope.launch { lock.withLock {
            if (!gate.accepts(ticket)) return@withLock
            try {
                val candidate = Session(Repo.candidates(), Repo.appliedSettings.value, Repo.activeProfile(), Repo.connectionRevision.get(), Repo.chainServer())
                require(candidate.servers.isNotEmpty()) { "Нет серверов — добавьте подписку" }
                applicationRules(candidate.settings) // Reject an empty include-list before touching a live tunnel.
                check(Repo.setVpnRequested(true)) { "Не удалось сохранить защищённые данные" }
                session = candidate; current = 0
                VpnState.since.value = null; VpnState.sessionBytes.value = 0
                if (startCore(ticket)) {
                    Repo.markConnectionApplied(candidate.revision)
                    startMonitoring(ticket)
                }
            } catch (e: Exception) {
                if (gate.accepts(ticket) && pfd != null && core?.isRunning == true) {
                    Repo.message.value = e.message ?: "Настройки не применены"
                    publish(VpnStatus.RECONNECTING); startMonitoring(ticket)
                } else fail(ticket, e.message ?: "Не удалось запустить VPN")
            } finally {
                main.post {
                    if (recoveryDeferral.finish(ticket) && gate.accepts(ticket)) scheduleRecovery("Изменилась сеть", ticket)
                }
            }
        } }
        return START_STICKY
    }

    private fun applicationRules(s: Settings) = VpnAppPolicy.rules(s.appsMode, s.apps, packageName) { name ->
        try { packageManager.getApplicationInfo(name, 0); true } catch (_: android.content.pm.PackageManager.NameNotFoundException) { false }
    }

    private fun startCore(ticket: Long): Boolean {
        val plan = session ?: return false
        if (!gate.accepts(ticket) || destroyed) return false
        val s = plan.settings
        val cfg = ConfigBuilder.build(plan.servers, current, s, plan.profile, chain = plan.chain)
        val rules = applicationRules(s)
        startHelper(plan.servers, s, ticket)
        if (!gate.accepts(ticket) || destroyed) return false
        val builder = Builder().setSession("Tutun").setMtu(1500)
            .addAddress("10.10.14.1", 30).addRoute("0.0.0.0", 0).addDnsServer("1.1.1.1")
            .setConfigureIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
        // No IPv6 address, route, DNS or allowFamily(AF_INET6): Android blocks IPv6 for this IPv4 VPN.
        if (rules.allowed != null) rules.allowed.forEach { builder.addAllowedApplication(it) }
        else rules.excluded.forEach { builder.addDisallowedApplication(it) }
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        underlying?.let { builder.setUnderlyingNetworks(arrayOf(it)) }
        val next = builder.establish() ?: error("Android не разрешил VPN — откройте системные настройки VPN")
        if (!gate.accepts(ticket) || destroyed) { next.close(); return false }
        val old = pfd
        try {
            runCatching { core?.stopLoop() }
            pfd = next
            GeoUpdates.prepareCore(this)
            val controller = Libv2ray.newCoreController(object : CoreCallbackHandler {
                override fun startup(): Long = 0
                override fun shutdown(): Long { if (gate.accepts(ticket)) scheduleRecovery("Ядро остановилось", ticket); return 0 }
                override fun onEmitStatus(code: Long, msg: String?): Long = 0 // Never copy native config/credentials into logcat.
            })
            core = controller
            controller.startLoop(cfg, next.fd)
        } catch (e: Exception) {
            fail(ticket, "Ядро не смогло запуститься. Проверьте сервер и настройки.")
            return false
        } finally { old?.close() }
        if (!gate.accepts(ticket) || destroyed) return false
        VpnState.server.value = plan.servers[current]
        VpnState.latencyMs.value = null
        publish(if (VpnState.since.value == null) VpnStatus.STARTING else VpnStatus.RECONNECTING)
        return true
    }

    /** Вспомогательный sing-box для TUIC/Hysteria2: перезапускается вместе с ядром, чтобы взять свежий DNS сети. */
    private fun startHelper(servers: List<Server>, s: Settings, ticket: Long) {
        stopHelper()
        val dns = SingBoxHelper.dnsServer(cm, underlying, s.directDNS)
        val cfg = SingBoxHelper.config(servers, SingBoxHelper.BASE_PORT, dns) ?: return
        val running = SingBoxHelper.start(cfg, SingBoxHelper.BASE_PORT, servers.count { it.usesSingBox }, "vpn")
        helper = running
        Thread({
            running.waitForExit()
            main.post { if (helper === running && gate.accepts(ticket) && !destroyed) scheduleRecovery("sing-box остановился", ticket) }
        }, "Tutun-singbox-watch").apply { isDaemon = true }.start()
    }
    private fun stopHelper() {
        val h = helper ?: return
        helper = null
        h.stop()
    }

    private fun scheduleRecovery(reason: String, expectedTicket: Long? = null) { main.post {
        if (destroyed || (expectedTicket != null && !gate.accepts(expectedTicket))) return@post
        if (recoveryDeferral.deferIfStarting(gate::accepts)) return@post
        if (session == null) return@post
        val ticket = gate.recover() ?: return@post
        cancelMonitoring()
        VpnState.latencyMs.value = null
        publish(VpnStatus.RECONNECTING)
        recoveryJob = scope.launch {
            delay(1_500)
            lock.withLock {
                if (!gate.accepts(ticket) || destroyed || session == null) return@withLock
                VpnState.write("$reason — восстанавливаю подключение")
                if (startCore(ticket)) startMonitoring(ticket)
            }
        }
    } }

    private fun startMonitoring(ticket: Long) {
        healthJob?.cancel(); statsJob?.cancel()
        val plan = session ?: return
        healthJob = scope.launch {
            var failures = 0
            while (isActive && gate.accepts(ticket)) {
                val ms = withContext(Dispatchers.IO) { check(ConfigBuilder.SOCKS_PORT, plan.settings) }
                var switch = false
                lock.withLock {
                    if (!gate.accepts(ticket) || destroyed) return@withLock
                    if (ms != null) {
                        failures = 0
                        if (VpnState.since.value == null) VpnState.since.value = System.currentTimeMillis()
                        VpnState.latencyMs.value = ms
                        if (VpnState.status.value != VpnStatus.RUNNING) {
                            publish(VpnStatus.RUNNING)
                            VpnState.write("Связь с сервером подтверждена")
                        }
                    } else {
                        VpnState.latencyMs.value = null
                        publish(VpnStatus.RECONNECTING)
                        failures++
                        switch = failures >= plan.settings.failLimit.coerceIn(1, 10)
                    }
                }
                if (switch && gate.accepts(ticket)) {
                    val best = coroutineScope {
                        plan.servers.indices.filter { it != current }.map { i ->
                            async(Dispatchers.IO) { i to check(ConfigBuilder.PROBE_BASE_PORT + i, plan.settings) }
                        }.awaitAll().filter { it.second != null }.minByOrNull { it.second!! }
                    }
                    lock.withLock { if (gate.accepts(ticket) && best != null) current = best.first }
                    if (gate.accepts(ticket)) scheduleRecovery("Сервер не отвечает", ticket)
                    return@launch
                }
                delay(plan.settings.probeIntervalSec.coerceIn(10, 300) * 1000L)
            }
        }
        statsJob = scope.launch {
            var tick = 0
            while (isActive && gate.accepts(ticket)) {
                delay(1000)
                lock.withLock {
                    if (!gate.accepts(ticket) || destroyed) return@withLock
                    val raw = runCatching { core?.queryAllOutboundTrafficStats() ?: "" }.getOrDefault("")
                    var up = 0L; var down = 0L
                    for (item in raw.split(";")) {
                        val f = item.split(",")
                        if (f.size != 3 || !f[0].startsWith("p")) continue
                        val value = f[2].toLongOrNull()?.coerceAtLeast(0) ?: continue
                        if (f[1] == "uplink") up += value else if (f[1] == "downlink") down += value
                    }
                    VpnState.speedUp.value = up; VpnState.speedDown.value = down
                    VpnState.sessionBytes.value += up + down; Repo.addTraffic(up, down)
                    if (++tick % 30 == 0) Repo.save()
                }
            }
        }
    }

    private fun check(port: Int, s: Settings): Int? {
        var conn: HttpURLConnection? = null
        return try {
            val start = android.os.SystemClock.elapsedRealtime()
            conn = URL(s.testURL).openConnection(Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port))) as HttpURLConnection
            conn.connectTimeout = s.testTimeoutSec.coerceIn(2, 30) * 1000
            conn.readTimeout = conn.connectTimeout
            conn.instanceFollowRedirects = false
            if (conn.responseCode in 200..399) (android.os.SystemClock.elapsedRealtime() - start).toInt() else null
        } catch (_: Exception) { null } finally { conn?.disconnect() }
    }

    private fun cancelMonitoring() {
        recoveryJob?.cancel(); healthJob?.cancel(); statsJob?.cancel()
    }
    private fun closeCore() {
        runCatching { core?.stopLoop() }; core = null
        runCatching { stopHelper() }
        runCatching { pfd?.close() }; pfd = null
        Repo.save()
        VpnState.server.value = null; VpnState.since.value = null; VpnState.latencyMs.value = null
        VpnState.speedUp.value = 0; VpnState.speedDown.value = 0
    }
    private fun fail(ticket: Long, message: String) {
        if (!gate.accepts(ticket)) return
        gate.stop(); cancelMonitoring(); Repo.setVpnRequested(false)
        closeCore()
        VpnState.error.value = message
        VpnState.write(message)
        publish(VpnStatus.FAILED)
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onRevoke() {
        val ticket = gate.stop(); cancelMonitoring(); Repo.setVpnRequested(false)
        scope.launch { lock.withLock {
            if (!gate.matches(ticket)) return@withLock
            closeCore(); publish(VpnStatus.STOPPED)
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        } }
    }
    override fun onDestroy() {
        destroyed = true; gate.stop(); cancelMonitoring()
        runCatching { cm.unregisterNetworkCallback(networkCallback) }
        runCatching { unregisterReceiver(wakeReceiver) }
        main.removeCallbacksAndMessages(null)
        // Finish any native launch first, then close its FD/controller; never race stopLoop against startLoop.
        scope.launch(NonCancellable) { lock.withLock {
            closeCore()
            if (VpnState.status.value != VpnStatus.FAILED) publish(VpnStatus.STOPPED)
        }; scope.cancel() }
        super.onDestroy()
    }

    private fun publish(status: VpnStatus) {
        VpnState.status.value = status
        if (status.isActive && !destroyed) showNotification(when (status) {
            VpnStatus.RUNNING -> tr("Подключено") + " · " + (VpnState.server.value?.cleanName ?: "Tutun")
            VpnStatus.STARTING -> tr("Подключение…")
            else -> tr("Переподключение…")
        })
        TileService.requestListeningState(this, ComponentName(this, QuickTile::class.java))
    }
    private fun showNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, TutunVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_lock_lock)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setContentTitle("Tutun").setContentText(text).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, tr("Отключить"), stop).build()).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(1, n)
    }
}
