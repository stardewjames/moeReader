package moe.reader.suwayomi

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class WireTest {
    @Test
    fun roundTripsEveryFieldType() {
        val bytes =
            WireWriter(4)
                .u8(0xFE)
                .bool(true)
                .i32(Int.MIN_VALUE)
                .i64(Long.MAX_VALUE - 1)
                .f64(-0.5)
                .string(null)
                .string("")
                .string("Ünïcødé 漫画 🙂")
                .bytes(null)
                .bytes(byteArrayOf(1, 2, 3))
                .strings(listOf("a", "bc"))
                .toByteArray()
        val reader = WireReader(bytes)
        assertEquals(0xFE, reader.u8())
        assertEquals(true, reader.bool())
        assertEquals(Int.MIN_VALUE, reader.i32())
        assertEquals(Long.MAX_VALUE - 1, reader.i64())
        assertEquals(-0.5, reader.f64())
        assertNull(reader.string())
        assertEquals("", reader.string())
        assertEquals("Ünïcødé 漫画 🙂", reader.string())
        assertNull(reader.bytes())
        assertContentEquals(byteArrayOf(1, 2, 3), reader.bytes())
        assertEquals(listOf("a", "bc"), reader.strings())
        assertEquals(0, reader.remaining)
    }

    @Test
    fun bigEndianLayoutMatchesTheSwiftReader() {
        // SuwayomiWireReader decodes this exact layout.
        val bytes = WireWriter().i32(0x01020304).string("hi").toByteArray()
        assertContentEquals(byteArrayOf(1, 2, 3, 4, 0, 0, 0, 2, 'h'.code.toByte(), 'i'.code.toByte()), bytes)
    }

    @Test
    fun truncatedMessagesAreRejected() {
        assertFailsWith<WireFormatException> { WireReader(byteArrayOf(0, 0, 0)).i32() }
        // A string longer than the remaining bytes.
        assertFailsWith<WireFormatException> { WireReader(WireWriter().i32(10).toByteArray()).string() }
        // A list count no message could hold.
        assertFailsWith<WireFormatException> { WireReader(WireWriter().i32(1_000).toByteArray()).strings() }
    }
}
