package moe.reader.suwayomi

import java.nio.file.Files

/** Boots the host once per test JVM, the way the app does, on [DesktopServices]. */
object TestHost {
    val services = DesktopServices()

    @Synchronized
    fun boot() {
        if (Host.isBooted) return
        val root = Files.createTempDirectory("suwayomi-host").toFile()
        Host.boot(HostConfig(root.resolve("data"), root.resolve("cache"), USER_AGENT), services)
    }

    const val USER_AGENT =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /** Runs one Bridge operation and unwraps the envelope. */
    fun call(
        op: Int,
        build: WireWriter.() -> Unit,
    ): WireReader {
        val reply = WireReader(Bridge.call(op, WireWriter().apply(build).toByteArray()))
        if (reply.u8() != 0) {
            val type = reply.string()
            val message = reply.string()
            throw AssertionError("$type: $message")
        }
        return reply
    }
}
