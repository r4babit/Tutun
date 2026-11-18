package app.tutun

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL
import java.io.File

internal object ReleaseUpdates {
    private const val releases = "https://github.com/r4babit/Tutun/releases"
    suspend fun latest(): String? = withContext(Dispatchers.IO) {
        val request = URL("$releases/latest/download/Tutun-release.json").openConnection()
        request.connectTimeout = 15000
        request.readTimeout = 20000
        val version = JSONObject(request.getInputStream().bufferedReader().use { it.readText() }).getString("version")
        require(version.matches(Regex("[0-9]+[.][0-9]+[.][0-9]+")))
        val firstDifference = version.split('.').map(String::toInt).zip(BuildConfig.VERSION_NAME.split('.').map(String::toInt)).firstOrNull { it.first != it.second }
        version.takeIf { firstDifference != null && firstDifference.first > firstDifference.second }
    }
    @Suppress("DEPRECATION")
    suspend fun download(ctx: Context, version: String): File = withContext(Dispatchers.IO) {
        val dir = File(ctx.cacheDir, "updates").apply { mkdirs() }
        val dest = File.createTempFile("Tutun-", ".apk", dir)
        try {
            val request = URL("$releases/download/v$version/Tutun-Android.apk").openConnection()
            request.connectTimeout = 15000
            request.readTimeout = 45000
            request.getInputStream().use { input -> dest.outputStream().use { output ->
                val buffer = ByteArray(131072)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= 314572800)
                    output.write(buffer, 0, read)
                }
            } }
            val pm = ctx.packageManager
            val candidate = requireNotNull(pm.getPackageArchiveInfo(dest.path, PackageManager.GET_SIGNATURES))
            val existing = pm.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNATURES)
            require(candidate.packageName == existing.packageName && candidate.versionName == version && candidate.versionCode > existing.versionCode)
            val trusted = existing.signatures.orEmpty().toSet()
            require(trusted.isNotEmpty() && trusted == candidate.signatures.orEmpty().toSet()) { "APK signing certificate mismatch" }
            dest
        } catch (e: Exception) { dest.delete(); throw e }
    }
}
