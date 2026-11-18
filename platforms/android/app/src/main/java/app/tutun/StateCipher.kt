package app.tutun

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Versioned, authenticated state envelope; keys remain in Android Keystore. */
object StateCipher {
    private val magic = byteArrayOf(0x54, 0x55, 0x54, 0x55, 0x4e, 1)
    private val aad = "Tutun.Android.State.v1".toByteArray(Charsets.UTF_8)
    fun encrypt(plain: ByteArray, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        require(cipher.iv.size == 12)
        cipher.updateAAD(aad)
        return magic + cipher.iv + cipher.doFinal(plain)
    }
    fun decrypt(data: ByteArray, key: SecretKey): ByteArray {
        require(data.size >= magic.size + 12 + 16 && data.take(magic.size).toByteArray().contentEquals(magic)) { "Invalid state envelope" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data.copyOfRange(magic.size, magic.size + 12)))
        cipher.updateAAD(aad)
        return cipher.doFinal(data.copyOfRange(magic.size + 12, data.size))
    }
}
