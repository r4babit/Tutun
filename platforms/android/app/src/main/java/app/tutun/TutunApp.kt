package app.tutun

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import libv2ray.Libv2ray

class TutunApp : Application() {
    companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    }

    override fun onCreate() {
        super.onCreate()
        // Гео-базы (geoip/geosite от runetfreedom): xray 26 читает их только файлами — копируем из APK в files/.
        copyGeo()
        GeoUpdates.prepareCore(this)
        SingBoxHelper.init(this)
        Repo.init(this)
        L10n.init(this, Repo.appliedSettings.value.language)
        // Opening a tile, receiving BOOT_COMPLETED or running device tests must not
        // send subscription/device data. Automatic refresh starts from the activity after the HWID choice.
    }

    /** Копирует гео-базы, если их нет или APK обновился (сравниваем с временем установки). */
    private fun copyGeo() {
        val installed = packageManager.getPackageInfo(packageName, 0).lastUpdateTime
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val dst = java.io.File(filesDir, name)
            if (dst.exists() && dst.lastModified() >= installed) continue
            val tmp = java.io.File(filesDir, "$name.tmp")
            assets.open(name).use { input -> tmp.outputStream().use { input.copyTo(it) } }
            tmp.renameTo(dst)
        }
    }
}
