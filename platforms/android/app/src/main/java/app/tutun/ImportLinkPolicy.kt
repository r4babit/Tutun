package app.tutun

object ImportLinkPolicy {
    val schemes = setOf("vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "wireguard", "wg", "socks", "socks5")
    fun accepts(value: String): Boolean {
        if (value.length !in 1..1_048_576) return false
        val scheme = value.substringBefore("://", "").lowercase(java.util.Locale.ROOT)
        return scheme in schemes || ((scheme == "happ" || scheme == "tutun") && value.substringAfter("://").startsWith("routing/"))
    }
}
