package app.tutun

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

@Composable
fun SubscriptionInfoScreen(id: String, close: () -> Unit) {
    val subs by Repo.subs.collectAsState()
    val servers by Repo.servers.collectAsState()
    val sub = subs.firstOrNull { it.id == id } ?: return
    var name by remember(id) { mutableStateOf(sub.name) }
    var interval by remember(id) { mutableStateOf(sub.updateIntervalHours) }
    var enabled by remember(id) { mutableStateOf(sub.enabled) }
    var show by remember { mutableStateOf(false) }
    var qr by remember { mutableStateOf(false) }
    var remove by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun link(url: String) {
        val uri = Uri.parse(url)
        if (uri.scheme in listOf("https", "http")) runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
    }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = C.bg) {
            Box(Modifier.fillMaxSize().systemBarsPadding().padding(16.dp)) {
                Column(Modifier.fillMaxSize()) {
                    SheetTitle(tr("Информация о подписке"))
                    LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 20.dp)) {
                        item { Card { Column(Modifier.padding(14.dp)) {
                            Text(sub.name, color = Color.White, fontSize = 20.sp)
                            Text("${bytes(sub.upload + sub.download)}" + if (sub.total > 0) tr(" из %@", bytes(sub.total)) else "", color = C.text2)
                            if (sub.total > 0) LinearProgressIndicator(progress = { ((sub.upload + sub.download).toDouble() / sub.total).coerceIn(0.0, 1.0).toFloat() }, modifier = Modifier.fillMaxWidth(), color = C.on)
                            Text(tr("Серверов: %@", servers.count { it.subId == id }), color = C.text2)
                            if (sub.expire > 0) Text(tr("Действует до: ") + java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM, L10n.locale).format(java.util.Date(sub.expire * 1000)), color = C.text2)
                            if (sub.lastUpdate > 0) Text(tr("Обновлена: ") + java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT, L10n.locale).format(java.util.Date(sub.lastUpdate * 1000)), color = C.text2)
                            sub.announce?.let { Text(it, color = C.text2) }
                            sub.lastError?.let { Text(it, color = C.bad) }
                        } } }
                        item { OutlinedTextField(name, { name = it }, label = { Text(tr("Название")) }, colors = fieldColors(), modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) }
                        item { Card { Column(Modifier.padding(14.dp)) {
                            Text(if (show) sub.url else "••••••••••••••••••", color = C.text2, maxLines = 3)
                            SecondaryButton(if (show) tr("Скрыть") else tr("Показать"), Modifier.fillMaxWidth()) { show = !show }
                        } } }
                        item { NumberChoiceRow(tr("Обновлять каждые"), interval, listOf(1, 3, 6, 12, 24, 48, 72, 168), 1..168, { tr("%@ ч", it) }) { interval = it } }
                        item { SwitchRow(tr("Показывать серверы этой подписки"), enabled) { enabled = it } }
                        item { Spacer(Modifier.height(12.dp)); SecondaryButton(tr("Скопировать ссылку"), Modifier.fillMaxWidth()) {
                            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Tutun", sub.url))
                            Repo.message.value = tr("Ссылка скопирована")
                        } }
                        item { SecondaryButton(tr("Показать QR-код"), Modifier.fillMaxWidth()) { qr = true } }
                        item { SecondaryButton(tr("Обновить"), Modifier.fillMaxWidth()) { scope.launch { Repo.updateSubscription(sub) } } }
                        item { sub.supportURL?.let { SecondaryButton(tr("Поддержка"), Modifier.fillMaxWidth()) { link(it) } } }
                        item { sub.webPageURL?.let { SecondaryButton(tr("Кабинет"), Modifier.fillMaxWidth()) { link(it) } } }
                        item { SecondaryButton(tr("Удалить подписку"), Modifier.fillMaxWidth(), C.bad) { remove = true } }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        SecondaryButton(tr("Отмена"), Modifier.weight(1f), onClick = close)
                        PrimaryButton(tr("Сохранить"), Modifier.weight(1f)) { Repo.saveSubscription(sub.copy(name = name.ifBlank { sub.name }, updateIntervalHours = interval, enabled = enabled)); close() }
                    }
                }
                PanelMessage(Modifier.align(Alignment.BottomCenter).padding(bottom = 64.dp))
            }
        }
        if (qr) SubscriptionQrDialog(sub.url) { qr = false }
        if (remove) AlertDialog(onDismissRequest = { remove = false }, title = { Text(tr("Удалить подписку и все её серверы?")) },
            confirmButton = { TextButton(onClick = { Repo.removeSubscription(sub); close() }) { Text(tr("Удалить")) } },
            dismissButton = { TextButton(onClick = { remove = false }) { Text(tr("Отмена")) } })
    }
}
