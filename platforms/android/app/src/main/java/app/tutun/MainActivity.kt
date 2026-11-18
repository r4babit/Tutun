package app.tutun

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Цвета Tutun (как DesignKit.swift на маке). */
object C {
    val bg = Color(0xFF11141B)
    val card = Color(0xFF181C26)
    val line = Color(0xFF252B39)
    val text2 = Color(0xFF8B93A7)
    val text3 = Color(0xFF6B7387)
    val selected = Color(0xFF1A2A26)
    val on = Color(0xFF1FB58F)
    val busy = Color(0xFFF2A33A)
    val bad = Color(0xFFE5484D)
    val off = Color(0xFF8A93A6)
}

class MainActivity : ComponentActivity() {
    val importText = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    private val importFile = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { readDocument(it, false) } }
    private val importQr = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { readDocument(it, true) } }
    /** Системный выбор файла: текст со ссылками/конфигом или картинка с QR-кодом. Всё читается локально. */
    fun chooseImportFile(qr: Boolean) {
        if (qr) importQr.launch(arrayOf("image/*"))
        else importFile.launch(arrayOf("text/*", "application/json", "application/octet-stream"))
    }
    private fun readDocument(uri: Uri, qr: Boolean) {
        lifecycleScope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    val bytes = requireNotNull(contentResolver.openInputStream(uri)).use { BoundedImport.read(it) }
                    if (qr) QrImageImport.decode(bytes)
                    else Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
                }
                importText.value = text
            } catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (_: Exception) { Repo.message.value = if (qr) tr("QR-код не найден") else tr("Нет подходящих серверов") }
        }
    }
    private fun receiveLink(incoming: Intent?) {
        val value = incoming?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString ?: return
        if (ImportLinkPolicy.accepts(value)) importText.value = value
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); receiveLink(intent) }

    private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (VpnService.prepare(this) == null) TutunVpnService.start(this)
        else Repo.message.value = tr("Без разрешения на VPN Tutun не может подключиться")
    }

    fun connect() {
        val i = VpnService.prepare(this)
        if (i != null) vpnPermission.launch(i) else TutunVpnService.start(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Repo.appliedSettings.value.geoAutoUpdate && System.currentTimeMillis() - GeoUpdates.updated.value >= 7L * 86400 * 1000) {
            GeoUpdates.start(applicationContext)
        }
        if (savedInstanceState == null) receiveLink(intent)
        if (Build.VERSION.SDK_INT >= 33) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) {}.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr) {
            MaterialTheme(colorScheme = darkColorScheme(primary = C.on, background = C.bg, surface = C.card)) {
                Surface(Modifier.fillMaxSize(), color = C.bg) { HomeScreen(this) }
            }
            }
        }
    }
}

enum class Sheet { ADD, SERVERS, SETTINGS }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(act: MainActivity) {
    L10n.language.collectAsState().value
    val status by VpnState.status.collectAsState()
    val server by VpnState.server.collectAsState()
    val latency by VpnState.latencyMs.collectAsState()
    val since by VpnState.since.collectAsState()
    val vpnError by VpnState.error.collectAsState()
    val message by Repo.message.collectAsState()
    val selection by Repo.selection.collectAsState()
    val pings by Repo.pings.collectAsState()
    val servers by Repo.servers.collectAsState()
    var sheet by remember { mutableStateOf<Sheet?>(null) }
    val incoming by act.importText.collectAsState()
    LaunchedEffect(incoming) { if (incoming != null) sheet = Sheet.ADD }
    val connected = status.isActive
    val preferences by Repo.settings.collectAsState()
    if (preferences.hwidConsentVersion < 1) HardwareIdConsentDialog { allow ->
        Repo.chooseHWID(allow)
    }
    LaunchedEffect(preferences.hwidConsentVersion) {
        if (preferences.hwidConsentVersion >= 1) Repo.refreshOnLaunch()
    }

    val (stateText, stateColor) = when (status) {
        VpnStatus.RUNNING -> tr("Подключено") to C.on
        VpnStatus.STARTING -> tr("Подключение…") to C.busy
        VpnStatus.RECONNECTING -> tr("Переподключение…") to C.busy
        VpnStatus.FAILED -> tr("Ошибка") to C.bad
        VpnStatus.STOPPED -> tr("Отключено") to C.off
    }
    // Что показать крупно: страна текущего сервера или выбранное.
    val shown = server ?: Repo.candidates().firstOrNull()
    val title = when {
        server != null -> server!!.countryCode?.let { Server.countryName(it) } ?: server!!.cleanName
        else -> Repo.selectionTitle()
    }
    val pickText = when (selection.kind) {
        "country" -> tr("самый быстрый из списка")
        "server" -> tr("выбран вручную")
        else -> tr("выбран автоматически")
    }

    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 20.dp)) {
        Spacer(Modifier.height(18.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).clip(CircleShape).background(stateColor))
            Spacer(Modifier.width(8.dp))
            Text(stateText, color = stateColor, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(6.dp))
        Text(title, color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Black, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(18.dp))

        // Карточка сервера
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(C.card).border(1.dp, C.line, RoundedCornerShape(14.dp))
            .clickable { sheet = Sheet.SERVERS }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(shown?.flag ?: "🌐", fontSize = 26.sp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(shown?.cleanName ?: tr("Нет серверов"), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(shown?.let { "${it.proto} · ${it.transport} · $pickText" } ?: tr("Добавьте подписку"), color = C.text2, fontSize = 13.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            shown?.let { s -> PingText(if (connected) latency else pings[s.id]) }
        }
        Spacer(Modifier.height(12.dp))

        // Цифры
        var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
        LaunchedEffect(connected) { while (connected) { now = System.currentTimeMillis(); delay(1000) } }
        if (connected) {
            val down by VpnState.speedDown.collectAsState()
            val history = remember(since) { mutableStateListOf<Float>().apply { repeat(60) { add(0f) } } }
            LaunchedEffect(since) {
                while (true) {
                    history.removeAt(0)
                    history.add((VpnState.speedDown.value + VpnState.speedUp.value).toFloat())
                    delay(1000)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatTile(tr("Задержка"), latency?.let { tr("%@ мс", it) } ?: "—", Modifier.weight(1f))
                StatTile(tr("Загрузка"), speed(down), Modifier.weight(1f))
                StatTile(tr("В сети"), since?.let { duration((now - it).coerceAtLeast(0) / 1000) } ?: "—", Modifier.weight(1f))
            }
            androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().padding(top = 18.dp).height(34.dp)) {
                val peak = (history.maxOrNull() ?: 1f).coerceAtLeast(1f)
                val path = androidx.compose.ui.graphics.Path()
                history.forEachIndexed { i, sample ->
                    val x = size.width * i / (history.size - 1)
                    val y = size.height * (0.96f - 0.92f * sample / peak)
                    if (i == 0) path.moveTo(x,y) else path.lineTo(x,y)
                }
                drawPath(path, androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(C.on, Color(0xff3b6fe8))),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(1.6.dp.toPx()))
                path.lineTo(size.width,size.height); path.lineTo(0f,size.height); path.close()
                drawPath(path, androidx.compose.ui.graphics.Brush.verticalGradient(listOf(C.on.copy(alpha=0.28f),Color.Transparent)))
            }
        }

        Spacer(Modifier.weight(1f))
        ApplyBar(act)
        ActionTiles(sheet) { sheet = it }
        Spacer(Modifier.height(12.dp))
        val busy = status == VpnStatus.STARTING
        Button(
            onClick = { if (connected || busy) TutunVpnService.stop(act) else act.connect() },
            modifier = Modifier.fillMaxWidth().height(60.dp),
            shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (connected || busy) Color(0xFFEDEDED) else C.on,
                contentColor = if (connected || busy) Color.Black else Color.White),
        ) { Text(if (connected || busy) tr("Отключить") else if (status == VpnStatus.FAILED) tr("Повторить подключение") else tr("Подключить"), fontSize = 19.sp, fontWeight = FontWeight.Bold) }
        Spacer(Modifier.height(18.dp))
    }

    if (sheet == null) PanelMessage(Modifier.align(Alignment.BottomCenter).padding(horizontal = 20.dp, vertical = 120.dp))
    }

    sheet?.let { s ->
        ModalBottomSheet(onDismissRequest = { if (sheet == Sheet.SETTINGS) Repo.discardDraft(); if (sheet == Sheet.ADD) act.importText.value = null; sheet = null }, containerColor = C.bg,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            dragHandle = { Box(Modifier.padding(vertical = 10.dp).size(36.dp, 4.dp).clip(CircleShape).background(C.line)) }) {
            Box(Modifier.fillMaxWidth()) {
                when (s) {
                    Sheet.ADD -> AddSheet(act, incoming ?: "") { act.importText.value = null; sheet = Sheet.SERVERS }
                    Sheet.SERVERS -> ServersSheet(onPick = { sel ->
                        Repo.select(sel); sheet = null
                        if (connected) act.connect()
                    })
                    Sheet.SETTINGS -> SettingsSheet(act)
                }
                PanelMessage(Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp, vertical = 18.dp))
            }
        }
    }
}

fun duration(sec: Long): String {
    val h = sec / 3600; val m = (sec % 3600) / 60; val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

@Composable
fun MessageBar(text: String, onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(C.card).border(1.dp, C.busy.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
        .padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Info, null, tint = C.busy, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(L10n.dynamic(text), color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Icon(Icons.Default.Close, tr("Закрыть"), tint = C.text2, modifier = Modifier.size(18.dp).clickable { onClose() })
    }
}

@Composable
fun StatTile(label: String, value: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(C.card).padding(horizontal = 12.dp, vertical = 10.dp)) {
        Text(label, color = C.text2, fontSize = 12.sp)
        Text(value, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
fun PingText(ms: Int?) {
    L10n.language.collectAsState().value
    val (t, c) = when {
        ms == null -> "—" to C.text3
        ms < 0 -> tr("нет") to C.bad
        ms < 300 -> tr("%@ мс", ms) to C.on
        ms < 800 -> tr("%@ мс", ms) to C.busy
        else -> tr("%@ мс", ms) to C.bad
    }
    Text(t, color = c, fontSize = 13.sp, fontWeight = FontWeight.Medium)
}

/** Три квадратика над кнопкой, как на маке. */
@Composable
fun ActionTiles(open: Sheet?, onOpen: (Sheet) -> Unit) {
    L10n.language.collectAsState().value
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(C.card).border(1.dp, C.line, RoundedCornerShape(14.dp)).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Tile(tr("Добавить"), Icons.Default.Add, open == Sheet.ADD, Modifier.weight(1f)) { onOpen(Sheet.ADD) }
        Tile(tr("Настройки"), Icons.Outlined.Settings, open == Sheet.SETTINGS, Modifier.weight(1f)) { onOpen(Sheet.SETTINGS) }
        Tile(tr("Серверы"), Icons.Default.FormatListBulleted, open == Sheet.SERVERS, Modifier.weight(1f)) { onOpen(Sheet.SERVERS) }
    }
}

@Composable
fun Tile(title: String, icon: ImageVector, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(10.dp)).background(if (selected) C.selected else Color.Transparent)
        .border(1.dp, if (selected) C.on.copy(alpha = 0.45f) else Color.Transparent, RoundedCornerShape(10.dp))
        .clickable(onClick = onClick).padding(vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = if (selected) Color.White else C.text2, modifier = Modifier.size(20.dp))
        Spacer(Modifier.height(4.dp))
        Text(title, color = if (selected) Color.White else C.text2, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

// MARK: - Добавить

@Composable
fun AddSheet(act: MainActivity, initial: String = "", onDone: () -> Unit) {
    val ctx = LocalContext.current
    var text by remember(initial) { mutableStateOf(initial) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp).imePadding()) {
        SheetTitle(tr("Добавить"))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton(tr("Файл"), Modifier.weight(1f)) { act.chooseImportFile(false) }
            SecondaryButton(tr("QR-картинка"), Modifier.weight(1f)) { act.chooseImportFile(true) }
        }
        Spacer(Modifier.height(12.dp))
        Text(tr("Ссылка на подписку или ссылки серверов (vless://, trojan://, ss://…)"), color = C.text2, fontSize = 13.sp)
        Spacer(Modifier.height(10.dp))
        OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 110.dp),
            placeholder = { Text("https://…", color = C.text3) },
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = C.on, unfocusedBorderColor = C.line,
                focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = C.on))
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton(tr("Вставить"), Modifier.weight(1f)) {
                val cm = ctx.getSystemService(ClipboardManager::class.java)
                cm.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString()?.let { text = it }
            }
            PrimaryButton(if (busy) tr("Загружаю…") else tr("Добавить"), Modifier.weight(1f), enabled = text.isNotBlank() && !busy) {
                busy = true
                scope.launch { Repo.addFromText(text); busy = false; onDone() }
            }
        }
    }
}

@Composable
fun SheetTitle(t: String, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(t, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        trailing()
    }
}

@Composable
fun PrimaryButton(t: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, modifier.height(48.dp), enabled = enabled, shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = C.on, contentColor = Color.White,
            disabledContainerColor = C.on.copy(alpha = 0.35f), disabledContentColor = Color.White.copy(alpha = 0.6f))) {
        Text(t, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun SecondaryButton(t: String, modifier: Modifier = Modifier, color: Color = Color.White, onClick: () -> Unit) {
    OutlinedButton(onClick, modifier.height(48.dp), shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, C.line),
        colors = ButtonDefaults.outlinedButtonColors(containerColor = C.card, contentColor = color)) {
        Text(t, fontWeight = FontWeight.Medium)
    }
}

// MARK: - Серверы

@Composable
fun ServersSheet(onPick: (Selection) -> Unit) {
    val servers by Repo.servers.collectAsState()
    val subs by Repo.subs.collectAsState()
    val pings by Repo.pings.collectAsState()
    val pinging by Repo.pinging.collectAsState()
    val selection by Repo.selection.collectAsState()
    val scope = rememberCoroutineScope()
    val preferences by Repo.appliedSettings.collectAsState()
    val activeServer by VpnState.server.collectAsState()
    var info by remember { mutableStateOf<String?>(null) }
    info?.let { id -> SubscriptionInfoScreen(id) { info = null } }
    var expanded by remember { mutableStateOf(setOf<String>()) }
    val usable = remember(servers, subs) { Repo.usable() }

    Column(Modifier.fillMaxWidth().fillMaxHeight(0.85f).padding(horizontal = 16.dp)) {
        SheetTitle(tr("Серверы")) {
            if (pinging) CircularProgressIndicator(Modifier.size(20.dp), color = C.on, strokeWidth = 2.dp)
            else Icon(Icons.Default.Refresh, tr("Проверить серверы"), tint = C.text2,
                modifier = Modifier.size(24.dp).clickable { scope.launch { Repo.pingAll() } })
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                ListRow(selected = selection.kind == "fastest", onClick = { onPick(Selection()) }) {
                    Icon(Icons.Default.Bolt, null, tint = C.on, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(12.dp))
                    Text(tr("Самый быстрый"), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    PingText(usable.mapNotNull { pings[it.id] }.filter { it > 0 }.minOrNull())
                }
            }
            val favs = preferences.favorites
            val favCountries = favs.filter { it.startsWith("c:") }.mapNotNull { key -> Repo.countries(usable).firstOrNull { "c:${it.code}" == key } }
            val favServers = usable.filter { "s:${it.id}" in favs }.sortedBy { it.cleanName.lowercase() }
            if (favCountries.isNotEmpty() || favServers.isNotEmpty()) {
                item { Text(tr("Избранное"), color = C.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 6.dp, top = 16.dp, bottom = 6.dp)) }
                for (c in favCountries) {
                    val key = "fav-c-" + c.code
                    val open = key in expanded
                    item(key = key) {
                        ListRow(selected = selection.kind == "country" && selection.value == c.code, onClick = { onPick(Selection("country", c.code)) }) {
                            Text(c.flag, fontSize = 22.sp); Spacer(Modifier.width(12.dp))
                            Text(c.name, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            PingText(c.servers.mapNotNull { pings[it.id] }.filter { it > 0 }.minOrNull())
                            StarButton("c:${c.code}")
                            Box(Modifier.size(40.dp).clickable { expanded = if (open) expanded - key else expanded + key }, contentAlignment = Alignment.Center) {
                                Icon(Icons.Default.ExpandMore, tr("Серверы страны"), tint = C.text2, modifier = Modifier.rotate(if (open) 180f else 0f))
                            }
                        }
                    }
                    if (open) items(c.servers, key = { key + it.id }) { server ->
                        ListRow(selected = selection.kind == "server" && selection.value == server.id, indent = true, onClick = { onPick(Selection("server", server.id)) }) {
                            Text(server.cleanName, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            PingText(pings[server.id]); StarButton("s:${server.id}")
                        }
                    }
                }
                items(favServers, key = { "fav-s-" + it.id }) { s ->
                    ListRow(selected = selection.kind == "server" && selection.value == s.id, onClick = { onPick(Selection("server", s.id)) }) {
                        Text(s.flag ?: "🌐", fontSize = 20.sp); Spacer(Modifier.width(12.dp))
                        Text(s.cleanName, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        PingText(pings[s.id])
                        StarButton("s:${s.id}")
                    }
                }
            }
            val groups = subs.map { Triple(it.id, it.name, usable.filter { server -> server.subId == it.id }) } +
                listOf(Triple("manual", tr("Свои серверы"), usable.filter { it.subId == null }))
            for ((id, name, list) in groups) {
                val subscription = subs.firstOrNull { it.id == id }
                if (list.isEmpty() && subscription == null) continue
                item(key = "sub-$id") {
                    Row(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(name, color = C.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f).clickable { if (subscription != null) Repo.toggleSubscription(id) })
                        if (subscription != null) {
                            IconButton(onClick = { info = id }) { Icon(Icons.Default.Info, tr("Информация о подписке"), tint = C.text2) }
                            IconButton(onClick = { Repo.toggleSubscription(id) }) {
                                Icon(if (subscription.collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess, tr("Свернуть"), tint = C.text2)
                            }
                        }
                    }
                }
                if (subscription?.collapsed == true) continue
                for (c in Repo.countries(list)) {
                    val key = id + "|" + c.code
                    val open = key in expanded
                    item(key = key) {
                        ListRow(selected = selection.kind == "country" && selection.value == c.code,
                            onClick = { onPick(Selection("country", c.code)) }) {
                            Text(c.flag, fontSize = 22.sp)
                            Spacer(Modifier.width(12.dp))
                            Text(c.name, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            PingText(c.servers.mapNotNull { pings[it.id] }.filter { it > 0 }.minOrNull())
                            StarButton("c:${c.code}")
                            Box(Modifier.size(40.dp).clickable { expanded = if (open) expanded - key else expanded + key }, contentAlignment = Alignment.Center) {
                                Icon(Icons.Default.ExpandMore, tr("Серверы страны"), tint = C.text2, modifier = Modifier.rotate(if (open) 180f else 0f))
                            }
                        }
                    }
                    if (open) items(c.servers, key = { key + it.id }) { s ->
                        ListRow(selected = selection.kind == "server" && selection.value == s.id, indent = true,
                            onClick = { onPick(Selection("server", s.id)) }) {
                            Column(Modifier.weight(1f)) {
                                Text(s.cleanName, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("${s.proto} · ${s.transport}" + if (activeServer?.id == s.id) tr(" · сейчас") else "", color = C.text3, fontSize = 12.sp)
                            }
                            PingText(pings[s.id])
                            StarButton("s:${s.id}")
                        }
                    }
                }
            }
            if (usable.isEmpty()) item {
                Text(tr("Серверов пока нет — нажмите «Добавить» и вставьте ссылку подписки."), color = C.text2, fontSize = 14.sp,
                    modifier = Modifier.padding(16.dp))
            }
        }
    }
}

@Composable
fun ListRow(selected: Boolean, indent: Boolean = false, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = if (indent) 22.dp else 0.dp, bottom = 4.dp).clip(RoundedCornerShape(12.dp))
        .background(if (selected) C.selected else C.card)
        .border(1.dp, if (selected) C.on.copy(alpha = 0.45f) else C.line, RoundedCornerShape(12.dp))
        .clickable(onClick = onClick).heightIn(min = 52.dp).padding(start = 14.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically, content = content)
}

// MARK: - Настройки

fun bytes(b: Long): String {
    val gb = b / 1_073_741_824.0
    return if (gb >= 1) tr("%.1f ГБ").format(L10n.locale, gb) else tr("%.0f МБ").format(L10n.locale, b / 1_048_576.0)
}

@Composable
fun Section(t: String) = Text(t, color = C.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
    modifier = Modifier.padding(start = 6.dp, top = 18.dp, bottom = 8.dp))

@Composable
fun Hint(t: String) = Text(t, color = C.text3, fontSize = 12.sp, modifier = Modifier.padding(start = 6.dp, top = 6.dp, end = 6.dp))

@Composable
fun Card(content: @Composable ColumnScope.() -> Unit) =
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(C.card).border(1.dp, C.line, RoundedCornerShape(12.dp)), content = content)

@Composable
fun Divider() = Box(Modifier.fillMaxWidth().padding(start = 14.dp).height(1.dp).background(C.line))

@Composable
fun SwitchRow(title: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!value) }.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(value, onChange, colors = SwitchDefaults.colors(checkedTrackColor = C.on, checkedThumbColor = Color.White,
            uncheckedTrackColor = C.line, uncheckedThumbColor = C.text2, uncheckedBorderColor = C.line))
    }
}

/** Выпадающий список в стиле Tutun (как на маке — вместо стрелочек). */
@Composable
fun <T> ChoiceRow(title: String, value: T, options: List<T>, label: (T) -> String, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label(value), color = C.on, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 180.dp))
                Icon(Icons.Default.ExpandMore, null, tint = C.text2, modifier = Modifier.size(20.dp))
            }
            DropdownMenu(open, { open = false }, containerColor = C.card, shape = RoundedCornerShape(12.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, C.line)) {
                options.forEach { o ->
                    DropdownMenuItem(text = { Text(label(o), color = if (o == value) C.on else Color.White) },
                        trailingIcon = { if (o == value) Icon(Icons.Default.Check, null, tint = C.on) },
                        onClick = { open = false; onPick(o) })
                }
            }
        }
    }
}

@Composable
fun NavRow(title: String, value: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(value, color = C.text2, fontSize = 15.sp)
        Icon(Icons.Default.ChevronRight, null, tint = C.text2, modifier = Modifier.size(20.dp))
    }
}

@Composable
fun HardwareIdConsentDialog(onChoice: (Boolean) -> Unit) {
    L10n.language.collectAsState().value
    AlertDialog(onDismissRequest = {}, title = { Text(tr("ID устройства для подписки")) },
        text = { Text(tr("По умолчанию ID не отправляется. Если провайдер ограничивает число устройств, можно разрешить отправку ID этого телефона, модели, версии Android и языка по адресу вашей подписки. Данные получает ваш провайдер при обновлении подписки. Выбор можно изменить в настройках.")) },
        confirmButton = { TextButton(onClick = { onChoice(true) }) { Text(tr("Разрешить отправку")) } },
        dismissButton = { TextButton(onClick = { onChoice(false) }) { Text(tr("Без ID устройства")) } })
}
