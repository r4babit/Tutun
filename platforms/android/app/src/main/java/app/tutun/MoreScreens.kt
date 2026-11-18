package app.tutun

import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Звёздочка избранного (страна «c:NL» или сервер «s:<id>»). */
@Composable
fun StarButton(key: String) {
    val s by Repo.settings.collectAsState()
    val on = key in s.favorites
    Box(Modifier.size(40.dp).clickable { Repo.toggleFavorite(key) }, contentAlignment = Alignment.Center) {
        Icon(if (on) Icons.Default.Star else Icons.Default.StarBorder, if (on) tr("Убрать из избранного") else tr("В избранное"),
            tint = if (on) C.busy else C.text3, modifier = Modifier.size(20.dp))
    }
}

/** Полноэкранное окно поверх шторки, в стиле Tutun. */
@Composable
fun FullDialog(title: String, onClose: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = C.bg) {
            Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 16.dp).imePadding()) {
                Row(Modifier.fillMaxWidth().padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    Text(tr("Готово"), color = C.on, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onClose() }.padding(8.dp))
                }
                content()
            }
        }
    }
}

private data class AppInfo(val pkg: String, val label: String, val icon: Drawable?)

/** Выбор приложений для «мимо VPN» / «только через VPN». */
@Composable
fun AppsDialog(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val s by Repo.settings.collectAsState()
    var apps by remember { mutableStateOf<List<AppInfo>?>(null) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        apps = withContext(Dispatchers.IO) {
            val pm = ctx.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            pm.queryIntentActivities(intent, PackageManager.MATCH_ALL).map { it.activityInfo.packageName }.distinct()
                .filter { it != ctx.packageName }
                .map { p ->
                    val ai = pm.getApplicationInfo(p, 0)
                    AppInfo(p, pm.getApplicationLabel(ai).toString(), try { pm.getApplicationIcon(ai) } catch (_: Exception) { null })
                }.sortedBy { it.label.lowercase() }
        }
    }
    val title = if (s.appsMode == "include") tr("Только через VPN") else tr("Мимо VPN")
    FullDialog(title, onClose) {
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, null, tint = C.text2) },
            placeholder = { Text(tr("Найти приложение"), color = C.text3) }, colors = fieldColors())
        Spacer(Modifier.height(8.dp))
        val list = apps
        if (list == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = C.on) }
        } else {
            // Выбранные — сверху.
            val shown = list.filter { query.isBlank() || it.label.contains(query, true) || it.pkg.contains(query, true) }
                .sortedBy { if (it.pkg in s.apps) 0 else 1 }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
                items(shown, key = { it.pkg }) { a ->
                    val on = a.pkg in s.apps
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable {
                        Repo.updateSettings { st -> st.copy(apps = if (on) st.apps - a.pkg else st.apps + a.pkg) }
                    }.padding(vertical = 8.dp, horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        val bmp = remember(a.pkg) { a.icon?.toBitmap(96, 96)?.asImageBitmap() }
                        if (bmp != null) Image(bmp, null, Modifier.size(36.dp)) else Spacer(Modifier.size(36.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(a.label, color = Color.White, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(a.pkg, color = C.text3, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Checkbox(on, null, colors = CheckboxDefaults.colors(checkedColor = C.on, uncheckedColor = C.text3, checkmarkColor = Color.White))
                    }
                }
            }
        }
    }
}

/** Свои сайты: напрямую / через VPN / блокировать. По одному на строку. */
@Composable
fun SitesDialog(onClose: () -> Unit) {
    val s by Repo.settings.collectAsState()
    var direct by remember { mutableStateOf(s.directSites.joinToString("\n")) }
    var proxy by remember { mutableStateOf(s.proxySites.joinToString("\n")) }
    var block by remember { mutableStateOf(s.blockSites.joinToString("\n")) }
    fun lines(t: String) = t.lines().map { it.trim() }.filter { it.isNotEmpty() }
    FullDialog(tr("Свои сайты"), onClose) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SecondaryButton(tr("Отмена"), Modifier.weight(1f), onClick = onClose)
            PrimaryButton(tr("Сохранить"), Modifier.weight(1f)) {
                Repo.updateSettings { it.copy(directSites = lines(direct), proxySites = lines(proxy), blockSites = lines(block)) }
                onClose()
            }
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Hint(tr("По одному на строку: example.com — сайт со всеми поддоменами. Можно geosite:… и regexp:…"))
                Spacer(Modifier.height(10.dp))
            }
            item { SitesField(tr("Напрямую"), direct) { direct = it } }
            item { SitesField(tr("Всегда через VPN"), proxy) { proxy = it } }
            item { SitesField(tr("Блокировать"), block) { block = it } }
        }
    }
}

@Composable
private fun SitesField(title: String, value: String, onChange: (String) -> Unit) {
    Text(title, color = C.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp, top = 10.dp, bottom = 6.dp))
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().heightIn(min = 110.dp), colors = fieldColors(),
        placeholder = { Text("example.com", color = C.text3) })
}

@Composable
fun fieldColors() = OutlinedTextFieldDefaults.colors(focusedBorderColor = C.on, unfocusedBorderColor = C.line,
    focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = C.on)

/** Трафик через VPN: сегодня, месяц, по дням. */
@Composable
fun StatsCard() {
    L10n.language.collectAsState().value
    val days by Repo.days.collectAsState()
    val session by VpnState.sessionBytes.collectAsState()
    val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).format(java.util.Date())
    val month = today.take(7)
    val todayBytes = days[today]?.let { it.first + it.second } ?: 0L
    val monthBytes = days.filterKeys { it.startsWith(month) }.values.sumOf { it.first + it.second }
    Card {
        StatLine(tr("Текущая сессия"), bytes(session))
        Divider()
        StatLine(tr("Сегодня"), bytes(todayBytes))
        Divider()
        StatLine(tr("Этот месяц"), bytes(monthBytes))
        // Последние 14 дней — полосками.
        val last = days.entries.sortedBy { it.key }.takeLast(14)
        if (last.isNotEmpty()) {
            Divider()
            val max = last.maxOf { it.value.first + it.value.second }.coerceAtLeast(1)
            Row(Modifier.fillMaxWidth().height(90.dp).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.Bottom) {
                last.forEach { (_, v) ->
                    val f = (v.first + v.second).toFloat() / max
                    Box(Modifier.weight(1f).fillMaxHeight(f.coerceAtLeast(0.03f)).clip(RoundedCornerShape(3.dp)).background(C.on.copy(alpha = 0.8f)))
                }
            }
        }
    }
}

@Composable
private fun StatLine(t: String, v: String) {
    Row(Modifier.fillMaxWidth().padding(14.dp)) {
        Text(t, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(v, color = C.text2, fontSize = 15.sp)
    }
}

/** Кнопка «Применить изменения»: появляется, если поменяли настройки при включённом VPN. */
@Composable
fun ApplyBar(act: MainActivity) {
    L10n.language.collectAsState().value
    val need by Repo.needsApply.collectAsState()
    val status by VpnState.status.collectAsState()
    if (need) {
        Box(Modifier.fillMaxWidth().padding(bottom = 10.dp).clip(RoundedCornerShape(12.dp)).background(C.on)
            .clickable { if (Repo.applySettings() && status.isActive) act.connect() }.padding(12.dp), contentAlignment = Alignment.Center) {
            Text(tr("Применить изменения"), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

fun speed(bps: Long): String = when {
    bps >= 1_048_576 -> tr("%.1f МБ/с").format(L10n.locale, bps / 1_048_576.0)
    bps >= 1024 -> tr("%.0f КБ/с").format(L10n.locale, bps / 1024.0)
    else -> tr("%@ Б/с", bps)
}
