package app.tutun

/** Called on the service's main thread: network bursts cannot replace a pending user settings snapshot. */
class RecoveryDeferral {
    private var starting: Long? = null
    private var pending = false
    fun begin(ticket: Long) { starting = ticket; pending = false }
    fun cancel() { starting = null; pending = false }
    fun deferIfStarting(isCurrent: (Long) -> Boolean): Boolean {
        if (starting?.let(isCurrent) != true) return false
        pending = true; return true
    }
    fun finish(ticket: Long): Boolean {
        if (starting != ticket) return false
        starting = null
        val result = pending; pending = false
        return result
    }
}
