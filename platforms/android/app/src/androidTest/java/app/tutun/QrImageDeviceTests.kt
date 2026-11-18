package app.tutun

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QrImageDeviceTests {
    @Test fun pngImportReadsUtf8QrLocally() {
        val value = "https://example.invalid/sub?name=тест&key=fixture"
        val matrix = SubscriptionQr.matrix(value)
        val pixels = IntArray(matrix.width * matrix.height) { i ->
            if (matrix[i % matrix.width, i / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
        }
        val bitmap = Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
        try {
            val bytes = java.io.ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            assertEquals(value, QrImageImport.decode(bytes))
            assertThrows(Exception::class.java) { QrImageImport.decode(byteArrayOf(1, 2, 3)) }
        } finally { bitmap.recycle() }
    }
}
