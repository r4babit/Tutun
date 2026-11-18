package app.tutun

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class SecureStateStore(private val directory: File, private val legacy: File, private val key: () -> SecretKey) {
    private val file = AtomicFile(File(directory, "state.enc"))
    constructor(ctx: Context) : this(ctx.noBackupFilesDir, File(ctx.filesDir, "state.json"), { stateKey() })

    @Synchronized fun read(): String? {
        return if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) {
            String(StateCipher.decrypt(file.openRead().use { it.readBytes() }, key()), Charsets.UTF_8)
        } else if (legacy.exists()) legacy.readText() else null
    }

    @Synchronized fun write(json: String) {
        directory.mkdirs()
        val encrypted = StateCipher.encrypt(json.toByteArray(Charsets.UTF_8), key())
        val stream = file.startWrite()
        try { stream.write(encrypted); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
        // Plaintext is removed only after the encrypted atomic write succeeded.
        removeLegacy()
    }

    fun removeLegacy() {
        for (old in listOf(legacy, File(legacy.parentFile, "state.json.tmp"))) {
            check(!old.exists() || old.delete()) { "Cannot remove legacy state" }
        }
    }

    companion object {
        private const val ALIAS = "app.tutun.state.v1"
        private fun stateKey(): SecretKey {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
            return gen.generateKey()
        }
    }
}
