package app.tutun

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService

/** После включения телефона — подключиться, если включено в настройках и разрешение на VPN уже дано. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!Repo.appliedSettings.value.connectOnBoot) return
        if (VpnService.prepare(ctx) != null) return
        TutunVpnService.start(ctx)
    }
}
