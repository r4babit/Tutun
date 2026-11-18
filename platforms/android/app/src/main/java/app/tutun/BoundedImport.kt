package app.tutun

import java.io.InputStream

/** Читает импортируемый файл целиком, но не больше лимита (как у ответа подписки). */
object BoundedImport {
    const val MAX_BYTES = 16 * 1024 * 1024
    fun read(input: InputStream, maximum: Int = MAX_BYTES): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (output.size() <= maximum) {
            val n = input.read(buffer, 0, minOf(buffer.size, maximum + 1 - output.size()))
            if (n < 0) break
            output.write(buffer, 0, n)
        }
        require(output.size() <= maximum) { "Import exceeds size limit" }
        return output.toByteArray()
    }
}
