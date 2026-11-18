package app.tutun

import java.net.URL

object SubscriptionRequestPolicy {
    fun sameOrigin(a: URL, b: URL): Boolean = a.protocol == b.protocol && a.host.equals(b.host, true) && a.defaultPortOrExplicit() == b.defaultPortOrExplicit()
    /** https — всегда; http — только с включённым «Разрешить подписки по http». */
    fun allowed(url: URL, allowHttp: Boolean) = !url.host.isNullOrEmpty() && (url.protocol == "https" || (allowHttp && url.protocol == "http"))
    fun requireAllowed(url: URL, allowHttp: Boolean) {
        require(url.protocol in setOf("http", "https") && !url.host.isNullOrEmpty()) { "Неверная ссылка подписки" }
        require(allowed(url, allowHttp)) { "Подписка по http:// не защищена. Если это ваша панель без https, включите «Разрешить подписки по http» в настройках подписок." }
    }
    fun redirect(from: URL, location: String, allowHttp: Boolean = false): URL = URL(from, location).also {
        require(allowed(it, allowHttp)) { "Подписка перенаправила на незащищённый адрес" }
    }
    fun sendDeviceHeaders(s: Settings) = s.hwidConsentVersion >= 1 && s.sendHWID
    /** Данные устройства — только по https и на тот же адрес, что и исходная ссылка. */
    fun deviceHeadersFor(url: URL, wanted: Boolean) = wanted && url.protocol == "https"
    private fun URL.defaultPortOrExplicit() = if (port == -1) defaultPort else port
}
