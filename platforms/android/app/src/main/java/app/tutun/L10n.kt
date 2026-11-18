package app.tutun

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import java.util.Locale

/** Uses the macOS source catalog. Provider/user names never pass through the translator. */
object L10n {
    val languages = listOf("system" to "", "en" to "English", "zh" to "中文（简体）", "hi" to "हिन्दी", "es" to "Español", "ar" to "العربية", "fr" to "Français", "bn" to "বাংলা", "pt" to "Português", "ru" to "Русский", "ur" to "اردو", "id" to "Bahasa Indonesia", "de" to "Deutsch", "ja" to "日本語", "mr" to "मराठी", "te" to "తెలుగు", "tr" to "Türkçe", "ta" to "தமிழ்", "vi" to "Tiếng Việt", "ko" to "한국어", "uk" to "Українська")
    val language = MutableStateFlow("system")
    // Snapshot state tracks reads even inside non-composable tr()/locale helpers and lazy-item lambdas.
    private val choice = androidx.compose.runtime.mutableStateOf("system")
    private var table = JSONObject()
    private var systemLanguages = listOf(Locale.getDefault().language)
    fun init(context: Context, choice: String) {
        table = context.assets.open("l10n.json").bufferedReader().use { JSONObject(it.readText()) }
        val locales = android.content.res.Resources.getSystem().configuration.locales
        systemLanguages = (0 until locales.size()).map { locales[it].language }
        select(choice)
    }
    fun resolve(choice: String, system: List<String> = systemLanguages): String {
        val supported = languages.map { it.first }.filter { it != "system" }
        return if (choice in supported) choice else system.firstOrNull { it in supported } ?: "en"
    }
    val current get() = resolve(choice.value)
    val locale: Locale get() = Locale.forLanguageTag(when (current) { "zh" -> "zh-CN"; "pt" -> "pt-BR"; else -> current })
    fun select(value: String) {
        val next = value.takeIf { v -> languages.any { it.first == v } } ?: "system"
        choice.value = next
        language.value = next
    }
    fun nativeName(code: String) = if (code == "system") text("Как в системе") else languages.firstOrNull { it.first == code }?.second ?: code
    fun text(key: String): String {
        if (current == "ru") return key
        val entry = table.optJSONObject(key) ?: return key
        return entry.optString(current).ifEmpty { entry.optString("en", key) }
    }
    fun dynamic(value: String): String {
        val exact = text(value)
        if (exact != value || current == "ru") return exact
        val colon = value.indexOf(": ")
        if (colon > 0) {
            val head = value.take(colon)
            val translated = text(head)
            if (head != translated) return translated + value.drop(colon)
        }
        return value
    }
}
fun tr(key: String, vararg args: Any?): String {
    var index = 0
    return Regex("%(?:([1-9])\\$)?@").replace(L10n.text(key)) { match ->
        val position = match.groupValues[1].toIntOrNull()?.minus(1) ?: index++
        args.getOrNull(position)?.toString() ?: ""
    }
}
