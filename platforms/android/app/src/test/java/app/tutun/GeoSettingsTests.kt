package app.tutun

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class GeoSettingsTests {
    @Test fun migrateOldSettingsAndRoundTripWithoutReconnect() {
        val old = Settings.from(JSONObject().put("wifiRulesEnabled", true).put("directCountry", "cn"))
        assertFalse(old.geoAutoUpdate)
        assertFalse(old.toJson().has("wifiRulesEnabled"))
        assertEquals("cn", old.directCountry)
        val weekly = old.copy(geoAutoUpdate = true)
        assertFalse(old.requiresReconnect(weekly))
        assertEquals(weekly, Settings.from(weekly.toJson()))
    }
}
