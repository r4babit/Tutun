package app.tutun

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.launch

@Composable
internal fun ReleaseCard(act: MainActivity) {
    val scope = rememberCoroutineScope()
    var version by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    Column(Modifier.padding(14.dp)) {
        if (status.isNotEmpty()) Text(status)
        if (busy) LinearProgressIndicator()
        Button(enabled = !busy, onClick = {
            scope.launch {
                busy = true
                try {
                    val next = version
                    if (next == null) {
                        version = ReleaseUpdates.latest()
                        status = version?.let { tr("Доступна версия %@", it) } ?: tr("У вас последняя версия")
                    } else if (!act.packageManager.canRequestPackageInstalls()) {
                        act.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.fromParts("package", act.packageName, null)))
                    } else {
                        val file = ReleaseUpdates.download(act, next)
                        val uri = FileProvider.getUriForFile(act, act.packageName + ".updates", file)
                        val install = Intent(Intent.ACTION_INSTALL_PACKAGE, uri)
                        install.flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                        act.startActivity(install)
                    }
                } catch (e: Exception) { status = e.localizedMessage ?: tr("Ошибка") }
                finally { busy = false }
            }
        }) { Text(if (version == null) tr("Проверить обновления") else tr("Установить и перезапустить")) }
    }
}
