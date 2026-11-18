package app.tutun

/** Tickets invalidate old health checks and queued recovery when the user changes intent. */
class VpnSessionGate {
    private var generation = 0L
    @Volatile var wanted = false; private set
    @Synchronized fun start(): Long { wanted = true; return ++generation }
    @Synchronized fun recover(): Long? = if (wanted) ++generation else null
    @Synchronized fun stop(): Long { wanted = false; return ++generation }
    @Synchronized fun matches(ticket: Long) = generation == ticket
    @Synchronized fun accepts(ticket: Long) = wanted && generation == ticket
}

object VpnAppPolicy {
    data class Rules(val allowed: List<String>?, val excluded: List<String>)
    fun rules(mode: String, selected: List<String>, ownPackage: String, installed: (String) -> Boolean): Rules {
        val apps = selected.filter { it != ownPackage && installed(it) }.distinct()
        return when (mode) {
            "include" -> {
                require(apps.isNotEmpty()) { "Выберите хотя бы одно установленное приложение для VPN" }
                Rules(apps, emptyList())
            }
            "exclude" -> Rules(null, apps + ownPackage)
            "off" -> Rules(null, listOf(ownPackage))
            else -> error("Неизвестный режим приложений")
        }
    }
}
