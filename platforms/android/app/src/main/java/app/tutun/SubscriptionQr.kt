package app.tutun

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

object SubscriptionQr {
    fun matrix(value: String) = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 768, 768,
        mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.MARGIN to 4))
}

/** Generated locally; the subscription URL is never sent to a QR website. */
@Composable
fun SubscriptionQrDialog(value: String, close: () -> Unit) {
    val bitmap = remember(value) { runCatching {
        val matrix = SubscriptionQr.matrix(value)
        val pixels = IntArray(matrix.width * matrix.height) { i -> if (matrix[i % matrix.width, i / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
        Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888).asImageBitmap()
    }.getOrNull() }
    AlertDialog(onDismissRequest = close, containerColor = C.card, title = { Text(tr("QR-код"), color = Color.White) },
        text = {
            if (bitmap != null) Image(bitmap, tr("QR-код"), modifier = Modifier.fillMaxWidth().aspectRatio(1f))
            else Text(tr("Слишком длинно для QR-кода"), color = C.text2)
        },
        confirmButton = { TextButton(onClick = close) { Text(tr("Закрыть"), color = C.on) } })
}
