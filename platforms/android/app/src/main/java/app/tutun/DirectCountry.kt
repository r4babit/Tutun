package app.tutun

/**
 * «Сайты страны — напрямую» (как DirectCountry.swift на маке и Windows).
 * В гео-базе runetfreedom IP-списки есть только у RU, CN, IR — для MM, TR, AE только доменная зона.
 */
object DirectCountry {
    val codes = listOf("ru", "cn", "ir", "mm", "tr", "ae")
    private val withIPs = setOf("ru", "cn", "ir")
    val russiaDomains = listOf(
        "geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$",
        "domain:yandex.net", "domain:yastatic.net", "domain:vk.com", "domain:userapi.com",
        "domain:mycdn.me", "domain:ok.ru", "domain:max.ru", "domain:gosuslugi.ru",
    )
    fun domains(code: String): List<String> = when (code) {
        "cn" -> listOf("geosite:cn", "regexp:\\.cn$")
        "ir" -> listOf("geosite:category-ir", "regexp:\\.ir$")
        "mm" -> listOf("geosite:category-bank-mm", "regexp:\\.mm$")
        "tr" -> listOf("regexp:\\.tr$")
        "ae" -> listOf("regexp:\\.ae$")
        else -> russiaDomains
    }
    fun ips(code: String): List<String> = if (code in withIPs) listOf("geoip:$code") else emptyList()
    fun dnsDomains(code: String): List<String> =
        if (code == "ru" || code !in codes) listOf("geosite:category-ru", "regexp:\\.ru$", "regexp:\\.xn--p1ai$") else domains(code)
    /** 77.88.8.8 (Яндекс) годится только для России; для других стран — DNS провайдера. */
    fun dnsAddress(code: String, directDNS: String) = if (code != "ru" && directDNS == "77.88.8.8") "localhost" else directDNS
}
