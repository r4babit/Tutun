package app.tutun

object AddressPolicy {
    /** Строка — IPv4-адрес (без разрешения имён). */
    fun isIpLiteral(value: String): Boolean {
        val parts = value.split('.')
        return parts.size == 4 && parts.all { it.isNotEmpty() && it.length <= 3 && it.all(Char::isDigit) && it.toInt() in 0..255 }
    }
    fun isPrivate(host: String): Boolean {
        val value = host.lowercase(java.util.Locale.ROOT).removePrefix("[").removeSuffix("]")
        if (value == "localhost") return true
        val parts = value.split('.')
        if (parts.size == 4 && parts.all { it.isNotEmpty() && it.all(Char::isDigit) && (it.toIntOrNull() ?: -1) in 0..255 }) {
            val ip = parts.map { it.toInt() }
            return ip[0] == 10 || ip[0] == 127 || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 172 && ip[1] in 16..31) || (ip[0] == 169 && ip[1] == 254)
        }
        if (':' !in value || value.any { it !in "0123456789abcdef:." }) return false
        val address = runCatching { java.net.InetAddress.getByName(value) }.getOrNull() ?: return false
        return address.isLoopbackAddress || address.isSiteLocalAddress || address.isLinkLocalAddress || (address.address.size == 16 && address.address[0].toInt() and 0xfe == 0xfc)
    }
}
