package moe.reader.suwayomi

/*
 * Wire format shared with MoeReader/SuwayomiCompat/SuwayomiWire.swift.
 *
 * Calls cross JNI as one byte array each way. The schema is positional: both
 * sides know the field order of every message, so there are no tags, keys or
 * reflection. That keeps encoding to a few array copies, which matters on an
 * interpreter-only JVM where a JSON codec would dominate small calls.
 *
 *   u8      one byte
 *   bool    u8, 0 or 1
 *   i32     4 bytes, big-endian
 *   i64     8 bytes, big-endian
 *   f64     i64 of the IEEE-754 bits
 *   string  i32 byte count (-1 = null), then UTF-8
 *   bytes   i32 byte count (-1 = null), then raw bytes
 *   list    i32 count, then the elements
 */

class WireWriter(
    initialCapacity: Int = 256,
) {
    private var buffer = ByteArray(initialCapacity)
    private var size = 0

    private fun ensure(extra: Int) {
        val needed = size + extra
        if (needed <= buffer.size) return
        var capacity = buffer.size * 2
        while (capacity < needed) capacity *= 2
        buffer = buffer.copyOf(capacity)
    }

    fun u8(value: Int): WireWriter {
        ensure(1)
        buffer[size++] = value.toByte()
        return this
    }

    fun bool(value: Boolean): WireWriter = u8(if (value) 1 else 0)

    fun i32(value: Int): WireWriter {
        ensure(4)
        buffer[size] = (value ushr 24).toByte()
        buffer[size + 1] = (value ushr 16).toByte()
        buffer[size + 2] = (value ushr 8).toByte()
        buffer[size + 3] = value.toByte()
        size += 4
        return this
    }

    fun i64(value: Long): WireWriter {
        i32((value ushr 32).toInt())
        return i32(value.toInt())
    }

    fun f64(value: Double): WireWriter = i64(value.toRawBits())

    fun string(value: String?): WireWriter = bytes(value?.toByteArray(Charsets.UTF_8))

    fun bytes(value: ByteArray?): WireWriter {
        if (value == null) return i32(-1)
        i32(value.size)
        ensure(value.size)
        System.arraycopy(value, 0, buffer, size, value.size)
        size += value.size
        return this
    }

    fun strings(values: Collection<String>): WireWriter {
        i32(values.size)
        for (value in values) string(value)
        return this
    }

    inline fun <T> list(
        values: Collection<T>,
        element: WireWriter.(T) -> Unit,
    ): WireWriter {
        i32(values.size)
        for (value in values) element(value)
        return this
    }

    fun toByteArray(): ByteArray = buffer.copyOf(size)
}

class WireFormatException(
    message: String,
) : IllegalArgumentException(message)

class WireReader(
    private val buffer: ByteArray,
) {
    private var position = 0

    val remaining: Int get() = buffer.size - position

    private fun need(count: Int) {
        if (count < 0 || count > buffer.size - position) {
            throw WireFormatException("truncated message: need $count bytes at $position of ${buffer.size}")
        }
    }

    fun u8(): Int {
        need(1)
        return buffer[position++].toInt() and 0xFF
    }

    fun bool(): Boolean = u8() != 0

    fun i32(): Int {
        need(4)
        val value =
            ((buffer[position].toInt() and 0xFF) shl 24) or
                ((buffer[position + 1].toInt() and 0xFF) shl 16) or
                ((buffer[position + 2].toInt() and 0xFF) shl 8) or
                (buffer[position + 3].toInt() and 0xFF)
        position += 4
        return value
    }

    fun i64(): Long {
        val high = i32().toLong()
        val low = i32().toLong() and 0xFFFFFFFFL
        return (high shl 32) or low
    }

    fun f64(): Double = Double.fromBits(i64())

    fun bytes(): ByteArray? {
        val count = i32()
        if (count == -1) return null
        need(count)
        val value = buffer.copyOfRange(position, position + count)
        position += count
        return value
    }

    fun string(): String? {
        val count = i32()
        if (count == -1) return null
        need(count)
        val value = String(buffer, position, count, Charsets.UTF_8)
        position += count
        return value
    }

    fun requireString(): String = string() ?: throw WireFormatException("unexpected null string at $position")

    fun strings(): List<String> = list { requireString() }

    inline fun <T> list(element: WireReader.() -> T): List<T> {
        val count = i32()
        if (count < 0 || count > remaining) throw WireFormatException("bad list count $count")
        val result = ArrayList<T>(count)
        repeat(count) { result.add(element()) }
        return result
    }
}
