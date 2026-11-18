package app.tutun

import android.content.pm.ApplicationInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.KeyGenerator

@RunWith(AndroidJUnit4::class)
class StorageDeviceTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(body: (File, File, SecureStateStore) -> Unit) {
        val alias = "app.tutun.test." + UUID.randomUUID()
        val directory = File(context.cacheDir, alias).apply { mkdirs() }
        val legacy = File(directory, "legacy/state.json").apply { parentFile!!.mkdirs() }
        val encrypted = File(directory, "encrypted")
        val gen = KeyGenerator.getInstance("AES", "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        val key = gen.generateKey()
        try { body(encrypted, legacy, SecureStateStore(encrypted, legacy) { key }) }
        finally { directory.deleteRecursively(); KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) } }
    }
    @Test fun actualKeystoreEncryptionMigratesLegacyAndWorksAfterReopen() = fixture { directory, legacy, store ->
        val json = """{"secret":"not-a-real-subscription","servers":[]}"""
        legacy.writeText(json)
        assertEquals(json, store.read())
        store.write(store.read()!!)
        assertFalse(legacy.exists())
        assertEquals(json, store.read())
        assertFalse(File(directory, "state.enc").readText().contains("not-a-real-subscription"))
        store.write(json); assertEquals(json, store.read())
    }
    @Test fun keyFailurePreservesPlaintextUntilSuccessfulMigration() = fixture { directory, legacy, _ ->
        val json = """{"secret":"migration-fixture"}"""
        legacy.writeText(json)
        val store = SecureStateStore(directory, legacy) { error("simulated locked key") }
        assertEquals(json, store.read())
        assertThrows(Exception::class.java) { store.write(json) }
        assertEquals(json, legacy.readText())
        assertFalse(File(directory, "state.enc").exists())
    }
    @Test fun corruptCiphertextIsNotSilentlyReplacedWithEmptyState() = fixture { directory, _, store ->
        store.write("{}")
        val file = File(directory, "state.enc")
        val bad = file.readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        file.writeBytes(bad)
        assertThrows(Exception::class.java) { store.read() }
        assertArrayEquals(bad, file.readBytes())
    }
    @Test fun allTwentyLanguagesLoadAndFormatFromInstalledCatalog() {
        val previous = L10n.language.value
        try {
            for ((code, _) in L10n.languages.filter { it.first != "system" }) {
                L10n.select(code)
                val settings = tr("Настройки")
                assertTrue(settings.isNotBlank())
                if (code != "ru") assertNotEquals("Настройки", settings)
                assertFalse(tr("Серверов: %@", 17).contains("%@"))
                assertTrue(tr("Серверов: %@", 17).contains("17"))
                assertFalse(tr("ID устройства для подписки").isBlank())
            }
        } finally { L10n.select(previous) }
    }
    @Test fun cloudBackupIsDisabledInInstalledManifest() {
        assertEquals(0, context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
    }
    @Test fun upgradePreservesExistingProfilesAndCredentials() {
        val args = InstrumentationRegistry.getArguments()
        val count = args.getString("expectedServers")
        org.junit.Assume.assumeNotNull(count)
        assertEquals(count!!.toInt(), Repo.servers.value.size)
        assertEquals(args.getString("expectedSubscriptions")!!.toInt(), Repo.subs.value.size)
        val normalized = Repo.servers.value.sortedBy { it.id }.joinToString("") { it.id + "\u0000" + it.outbound + "\u0000" }
        val digest = MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        assertEquals(args.getString("expectedOutboundDigest"), digest)
        assertFalse(File(context.filesDir, "state.json").exists())
        assertTrue(File(context.noBackupFilesDir, "state.enc").exists())
        // Legacy implicit sendHWID=true is not consent.
        if (Repo.appliedSettings.value.hwidConsentVersion < 1) assertFalse(SubscriptionRequestPolicy.sendDeviceHeaders(Repo.appliedSettings.value))
    }
}
