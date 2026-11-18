package app.tutun

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun SettingsSheet(act: MainActivity) {
    val ctx = LocalContext.current
    val s by Repo.settings.collectAsState()
    val accepted by Repo.appliedSettings.collectAsState()
    val log by VpnState.log.collectAsState()
    val profiles by Repo.profiles.collectAsState()
    val servers by Repo.servers.collectAsState()
    var tab by remember { mutableStateOf(0) }
    var apps by remember { mutableStateOf(false) }
    var sites by remember { mutableStateOf(false) }
    var hwid by remember { mutableStateOf(false) }
    if (apps) AppsDialog { apps = false }
    if (sites) SitesDialog { sites = false }
    if (hwid) HardwareIdConsentDialog { Repo.chooseHWID(it); hwid = false }
    Column(Modifier.fillMaxWidth().fillMaxHeight(0.88f).padding(horizontal = 16.dp)) {
        SheetTitle(tr("Настройки"))
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 24.dp)) {
            when (tab) {
                0 -> {
                    item { Section(tr("Основные")) }
                    item { Card {
                        ChoiceRow(tr("Язык интерфейса"), accepted.language, L10n.languages.map { it.first }, { L10n.nativeName(it) }) { Repo.setLanguage(it) }
                        Divider()
                        SwitchRow(tr("Подключаться при включении телефона"), s.connectOnBoot) { v -> Repo.updateSettings { it.copy(connectOnBoot = v) } }
                    } }
                    item { Section(tr("Клик по стране")) }
                    item { Card {
                        ChoiceRow(tr("К какому серверу подключаться"), s.countryPick, listOf("fastest", "lastUsed", "first", "random"), {
                            mapOf("fastest" to tr("Самый быстрый из списка"), "lastUsed" to tr("Последний выбранный в стране"), "first" to tr("Первый в списке"), "random" to tr("Случайный"))[it] ?: it
                        }) { v -> Repo.updateSettings { it.copy(countryPick = v) } }
                        Divider()
                        SwitchRow(tr("Сначала избранные серверы страны"), s.countryPreferFavorites) { v -> Repo.updateSettings { it.copy(countryPreferFavorites = v) } }
                        Divider()
                        SwitchRow(tr("Запасной сервер"), s.failover) { v -> Repo.updateSettings { it.copy(failover = v) } }
                    } }
                    item { Hint(tr("Пока сервер отвечает, Tutun остаётся на нём. Перестал отвечать — переходит на самый быстрый из рабочих в том же списке.")) }
                }
                1 -> {
                    item { Section(tr("Маршруты")) }
                    item { Card {
                        ChoiceRow(tr("Режим"), s.routingMode, listOf("rule", "global", "direct"), {
                            mapOf("rule" to tr("По правилам"), "global" to tr("Всё через VPN"), "direct" to tr("Напрямую"))[it] ?: it
                        }) { v -> Repo.updateSettings { it.copy(routingMode = v) } }
                        Divider()
                        ChoiceRow(tr("Сайты страны — напрямую"), if (s.russiaDirect) s.directCountry else "", listOf("") + DirectCountry.codes, {
                            mapOf("" to tr("Нет — всё по остальным правилам"), "ru" to tr("Россия"), "cn" to tr("Китай"), "ir" to tr("Иран"),
                                "mm" to tr("Мьянма"), "tr" to tr("Турция"), "ae" to tr("ОАЭ"))[it] ?: it
                        }) { v -> Repo.updateSettings { if (v.isEmpty()) it.copy(russiaDirect = false) else it.copy(russiaDirect = true, directCountry = v) } }
                        Divider()
                        SwitchRow(tr("Блокировать рекламу"), s.blockAds) { v -> Repo.updateSettings { it.copy(blockAds = v) } }
                    } }
                    item { Section(tr("Гео-базы")) }
                    item { GeoUpdateCard() }
                    item { Section(tr("Профиль маршрутов")) }
                    item { Card {
                        ChoiceRow(tr("Профиль маршрутов"), s.profileId ?: "", listOf("") + profiles.map { it.id }, { id -> profiles.firstOrNull { it.id == id }?.name ?: tr("Нет") }) { v -> Repo.updateSettings { it.copy(profileId = v.ifEmpty { null }) } }
                        Divider()
                        NavRow(tr("Свои сайты"), "") { sites = true }
                    } }
                    item { Hint(tr("Банки, госуслуги и местные сервисы выбранной страны идут без VPN. Россия, Китай, Иран — готовые списки сайтов и IP-адреса страны; Мьянма — банки и доменная зона; Турция, ОАЭ — только доменная зона (.tr, .ae).")) }
                    item { Section(tr("Приложения")) }
                    item { Card {
                        ChoiceRow(tr("Через VPN идут"), s.appsMode, listOf("off", "exclude", "include"), {
                            mapOf("off" to tr("Все приложения"), "exclude" to tr("Все, кроме выбранных"), "include" to tr("Только выбранные"))[it] ?: it
                        }) { v -> Repo.updateSettings { it.copy(appsMode = v) } }
                        if (s.appsMode != "off") { Divider(); NavRow(tr("Выбрать приложения"), "${s.apps.size}") { apps = true } }
                    } }
                    item { Hint(tr("При системной блокировке без VPN исключённые приложения теряют интернет. Режим «Только выбранные» требует хотя бы одно установленное приложение.")) }
                }
                2 -> {
                    item { Section(tr("Автопереключение")) }
                    item { Card {
                        NumberChoiceRow(tr("Проверять связь каждые"), s.probeIntervalSec, listOf(10, 20, 30, 60, 120, 300), 10..300, { tr("%@ с", it) }) { v -> Repo.updateSettings { it.copy(probeIntervalSec = v) } }
                        Divider()
                        NumberChoiceRow(tr("Сервер не отвечает после"), s.failLimit, listOf(1, 2, 3, 4, 5), 1..10, { tr("%@ неудач", it) }) { v -> Repo.updateSettings { it.copy(failLimit = v) } }
                    } }
                    item { Section(tr("Цепочка серверов")) }
                    item { Card {
                        ChoiceRow(tr("Первый сервер"), s.chainServerId ?: "", listOf("") + servers.filter { LinkParser.rejectReason(it) == null && ChainPolicy.supports(it) }.map { it.id }, { id -> servers.firstOrNull { it.id == id }?.cleanName ?: tr("Нет") }) { id -> Repo.updateSettings { it.copy(chainServerId = id.ifEmpty { null }) } }
                    } }
                    item { Section("DNS") }
                    item { Card {
                        SettingField(tr("DNS через VPN"), s.remoteDNS) { v -> Repo.updateSettings { it.copy(remoteDNS = v) } }
                        SettingField(tr("Для сайтов страны (напрямую)"), s.directDNS) { v -> Repo.updateSettings { it.copy(directDNS = v) } }
                        SettingField(tr("Адрес проверки связи"), s.testURL) { v -> Repo.updateSettings { it.copy(testURL = v) } }
                    } }
                    item { Hint(tr("77.88.8.8 — для России; при другой стране вместо него берётся DNS провайдера.")) }
                    item { Card {
                        SwitchRow(tr("Без тестовых серверов в «Самом быстром»"), s.skipNoFlag) { v -> Repo.updateSettings { it.copy(skipNoFlag = v) } }
                        Divider()
                        SwitchRow(tr("Фрагментация"), s.fragment) { v -> Repo.updateSettings { it.copy(fragment = v) } }
                        Divider()
                        SwitchRow("Mux", s.mux) { v -> Repo.updateSettings { it.copy(mux = v) } }
                    } }
                    item { Card { NavRow(tr("Постоянный VPN и блокировка без VPN"), "Android") { ctx.startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS)) } } }
                    item { Hint(tr("В системных настройках выберите Tutun, включите «Постоянный VPN» и при необходимости «Блокировать соединения без VPN». Автозапуск Tutun сам по себе не блокирует утечки. В этой версии IPv6 блокируется Android; подключение работает по IPv4.")) }
                }
                3 -> {
                    item { Section(tr("Подписки")) }
                    item { Card {
                        SwitchRow(tr("Отправлять ID устройства"), accepted.sendHWID) { if (it) hwid = true else Repo.chooseHWID(false) }
                        Divider()
                        SwitchRow(tr("Обновлять подписки при запуске"), s.updateOnLaunch) { v -> Repo.updateSettings { it.copy(updateOnLaunch = v) } }
                        Divider()
                        SwitchRow(tr("Разрешить подписки по http"), s.allowHttpSubscriptions) { v -> Repo.updateSettings { it.copy(allowHttpSubscriptions = v) } }
                    } }
                    item { Hint(tr("Небезопасно: по http ключи серверов видны провайдеру и любому в сети, список могут подменить. Включайте только для своей панели без https. ID устройства по http не отправляется.")) }
                    item { Section(tr("Статистика")) }
                    item { StatsCard() }
                    item { Section(tr("Журнал")) }
                    item { Card { Text(log.takeLast(60).joinToString("\n").ifEmpty { tr("Пока пусто") }, color = C.text2, fontSize = 11.sp, modifier = Modifier.padding(14.dp)) } }
                }
                else -> {
                    item { Section(tr("О Tutun")) }
                    item { Card { Column(Modifier.padding(16.dp)) {
                        Text("Tutun", color = Color.White, fontSize = 24.sp)
                        Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = C.text2)
                        Text(BuildConfig.BUILD_STAMP, color = C.text3, fontSize = 12.sp)
                        Text("xray ${remember { libv2ray.Libv2ray.checkVersionX() }}", color = C.text2)
                    } } }
                    item { Section(tr("Обновления")) }
                    item { Card { ReleaseCard(act) } }
                }
            }
        }
        ApplyBar(act)
        val labels = listOf(tr("Основные"), tr("Маршруты"), tr("Сеть"), tr("Ещё"), tr("О Tutun"))
        val icons = listOf(Icons.Default.Tune, Icons.Default.Route, Icons.Default.Public, Icons.Default.MoreHoriz, Icons.Default.Info)
        Row(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
            labels.forEachIndexed { i, label ->
                Column(Modifier.weight(1f).clickable { tab = i }.padding(vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(icons[i], null, tint = if (tab == i) C.on else C.text3)
                    Text(label, color = if (tab == i) Color.White else C.text3, fontSize = 10.sp, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun SettingField(title: String, value: String, change: (String) -> Unit) {
    OutlinedTextField(value, change, label = { Text(title) }, colors = fieldColors(), singleLine = true,
        modifier = Modifier.fillMaxWidth().padding(12.dp))
}

@Composable
fun PanelMessage(modifier: Modifier = Modifier) {
    val message by Repo.message.collectAsState()
    val error by VpnState.error.collectAsState()
    val text = message ?: error
    if (text != null) {
        LaunchedEffect(text) { kotlinx.coroutines.delay(4_000); if (Repo.message.value == text) Repo.message.value = null; if (VpnState.error.value == text) VpnState.error.value = null }
        Box(modifier) { MessageBar(text) { Repo.message.value = null; VpnState.error.value = null } }
    }
}

@Composable
fun NumberChoiceRow(title: String, value: Int, options: List<Int>, range: IntRange, label: (Int) -> String, onPick: (Int) -> Unit) {
    var custom by remember { mutableStateOf(false) }
    var input by remember(value) { mutableStateOf(value.toString()) }
    ChoiceRow(title, value, options + Int.MIN_VALUE, { if (it == Int.MIN_VALUE) tr("Другое значение…") else label(it) }) {
        if (it == Int.MIN_VALUE) custom = true else { custom = false; onPick(it) }
    }
    if (custom) Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(input, { text -> input = text.filter(Char::isDigit).take(4) }, modifier = Modifier.weight(1f), singleLine = true,
            isError = input.toIntOrNull() !in range, colors = fieldColors(),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number))
        Spacer(Modifier.width(10.dp))
        TextButton(onClick = { input.toIntOrNull()?.takeIf { it in range }?.let { onPick(it); custom = false } }, enabled = input.toIntOrNull() in range) { Text(tr("Сохранить"), color = C.on) }
    }
}
