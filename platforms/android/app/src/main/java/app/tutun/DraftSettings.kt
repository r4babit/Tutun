package app.tutun

import kotlinx.coroutines.flow.MutableStateFlow

/** Mirrors the Mac draft: only accept() persists normal settings. Metadata is independent. */
class DraftSettings(initial: Settings = Settings()) {
    val draft = MutableStateFlow(initial)
    val accepted = MutableStateFlow(initial)
    val dirty get() = draft.value != accepted.value
    fun load(value: Settings) { accepted.value = value; draft.value = value }
    fun edit(change: (Settings) -> Settings) { draft.value = change(draft.value) }
    fun accept(persist: (Settings) -> Boolean): Boolean {
        val next = draft.value
        if (!persist(next)) return false
        accepted.value = next
        return true
    }
    fun immediate(change: (Settings) -> Settings, persist: (Settings) -> Boolean): Boolean {
        val next = change(accepted.value)
        if (!persist(next)) return false
        accepted.value = next; draft.value = change(draft.value)
        return true
    }
}
