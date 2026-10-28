package moe.reader.suwayomi

object HostVersion {
    const val NAME = "1.0.0"
    const val CODE = 100

    /**
     * Bumped whenever the wire schema changes. The app refuses a host jar with a
     * different value instead of misreading its replies.
     */
    const val PROTOCOL = 1

    /**
     * Part of the converted-jar cache key: bump when the dex2jar settings or the
     * bytecode fix-ups change, so stale conversions are rebuilt.
     */
    const val CONVERTER = 1
}
