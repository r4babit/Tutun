package app.tutun

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class ImportBoundsTests {
    @Test fun exactLimitAndEmptyImportWorkButOversizeIsRejected() {
        assertArrayEquals(ByteArray(8), BoundedImport.read(ByteArrayInputStream(ByteArray(8)), 8))
        assertTrue(BoundedImport.read(ByteArrayInputStream(byteArrayOf()), 8).isEmpty())
        assertThrows(IllegalArgumentException::class.java) { BoundedImport.read(ByteArrayInputStream(ByteArray(9)), 8) }
    }
}
