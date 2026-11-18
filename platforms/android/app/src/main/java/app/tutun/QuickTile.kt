package app.tutun

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.combine

/** Плитка в шторке быстрых настроек: включить/выключить VPN одним касанием. */
class QuickTile : TileService() {
    private var job: Job? = null

    override fun onStartListening() {
        job?.cancel()
        job = CoroutineScope(Dispatchers.Main).launch {
            VpnState.status.combine(VpnState.server) { status, _ -> status }.collect { update(it) }
        }
    }

    override fun onStopListening() { job?.cancel(); job = null }
    override fun onDestroy() { job?.cancel(); super.onDestroy() }

    override fun onClick() {
        val on = VpnState.status.value.isActive
        if (on) { TutunVpnService.stop(this); return }
        if (VpnService.prepare(this) != null) {
            // Разрешение на VPN ещё не дано — открываем приложение.
            val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(android.app.PendingIntent.getActivity(this, 0, i, android.app.PendingIntent.FLAG_IMMUTABLE))
            } else collapseLegacy(i)
            return
        }
        TutunVpnService.start(this)
    }

    // The PendingIntent overload does not exist before API 34.
    @android.annotation.SuppressLint("StartActivityAndCollapseDeprecated")
    @Suppress("DEPRECATION")
    private fun collapseLegacy(intent: Intent) { startActivityAndCollapse(intent) }

    private fun update(st: VpnStatus) {
        val t = qsTile ?: return
        t.state = when (st) {
            VpnStatus.RUNNING, VpnStatus.RECONNECTING, VpnStatus.STARTING -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        if (Build.VERSION.SDK_INT >= 29) t.subtitle = when (st) {
            VpnStatus.RUNNING -> VpnState.server.value?.countryCode?.let { Server.countryName(it) } ?: tr("Подключено")
            VpnStatus.STARTING, VpnStatus.RECONNECTING -> tr("Подключение…")
            else -> tr("Отключено")
        }
        t.updateTile()
    }
}
