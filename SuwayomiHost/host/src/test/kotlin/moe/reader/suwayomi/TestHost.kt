package moe.reader.suwayomi

import java.io.File
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

    /** Package, extension classes and content key of an APK, read as the app does. */
    fun headerFor(apk: File): ExtensionHeader {
        val (packageName, classNames) =
            net.dongliu.apk.parser.ApkFile(apk).use { parsed ->
                val pkg = parsed.apkMeta.packageName
                val raw =
                    Regex("""android:name="tachiyomi\.extension\.class"\s+android:value="([^"]+)"""")
                        .find(parsed.manifestXml)
                        ?.groupValues
                        ?.get(1) ?: error("no extension class metadata")
                pkg to raw.split(';').map { if (it.startsWith(".")) pkg + it else it }
            }
        val key =
            java.security.MessageDigest.getInstance("SHA-256")
                .digest(apk.readBytes())
                .joinToString("") { "%02x".format(it) }
        return ExtensionHeader(packageName, apk.absolutePath, key, classNames)
    }

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

/** The extension header every source operation starts with. */
fun WireWriter.writeHeader(header: ExtensionHeader) {
    string(header.packageName)
    string(header.apkPath)
    string(header.apkKey)
    strings(header.classNames)
}
