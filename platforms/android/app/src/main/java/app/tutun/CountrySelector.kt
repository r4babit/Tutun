package app.tutun

object CountrySelector {
    fun candidates(all: List<Server>, selection: Selection, s: Settings, pings: Map<String, Int>, random: (List<Server>) -> Server = { it.random() }): List<Server> {
        fun byPing(list: List<Server>) = list.sortedBy { pings[it.id]?.takeIf { it >= 0 } ?: Int.MAX_VALUE }
        fun aliveOrAll(list: List<Server>) = list.filter { (pings[it.id] ?: 0) >= 0 }.ifEmpty { list }
        fun one(primary: Server, pool: List<Server>) = listOf(primary) + if (s.failover) byPing(aliveOrAll(pool.filter { it.id != primary.id })).take(1) else emptyList()
        val auto = if (s.skipNoFlag) all.filter { it.countryCode != null }.ifEmpty { all } else all
        if (selection.kind == "server") all.firstOrNull { it.id == selection.value }?.let { return one(it, auto) }
        if (selection.kind == "country") {
            var country = all.filter { (it.countryCode ?: "??") == selection.value }
            if (s.countryPreferFavorites) country = country.filter { "s:${it.id}" in s.favorites }.ifEmpty { country }
            if (country.isNotEmpty()) {
                val pool = aliveOrAll(country)
                when (s.countryPick) {
                    "lastUsed" -> country.firstOrNull { it.id == s.lastServerByCountry[selection.value] }?.let { return one(it, pool) }
                    "first" -> return one(pool.minBy { it.cleanName.lowercase() }, pool)
                    "random" -> return one(random(pool), pool)
                }
                return byPing(pool).take(10)
            }
        }
        return byPing(aliveOrAll(auto)).take(10)
    }
}
