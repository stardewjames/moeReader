package moe.reader.suwayomi

import moe.reader.suwayomi.net.NativeNetInterceptor
import xyz.nulldev.androidcompat.io.sharedprefs.PreferenceFiles
import java.io.File

/**
 * The host's only entry point. The app's JNI shim calls [call] on one of its
 * worker threads; the call runs to completion on that thread and returns the
 * encoded reply. The host adds no server, polling loop or periodic jobs.
 * Extensions can still create their own asynchronous work.
 *
 * Reply envelope: u8 0 + payload, or u8 1 + exception class + message.
 */
object Bridge {
    const val INIT = 1
    const val LOAD = 2
    const val POPULAR = 3
    const val LATEST = 4
    const val SEARCH = 5
    const val FILTERS = 6
    const val DETAILS = 7
    const val CHAPTERS = 8
    const val PAGES = 9
    const val IMAGE = 10
    const val PREFERENCES = 11
    const val SET_PREFERENCE = 12
    const val UNLOAD = 13
    const val TRIM = 14

    @JvmStatic
    fun call(
        op: Int,
        request: ByteArray,
    ): ByteArray =
        try {
            val reader = WireReader(request)
            val writer = WireWriter()
            writer.u8(0)
            dispatch(op, reader, writer)
            writer.toByteArray()
        } catch (error: Throwable) {
            if (error is OutOfMemoryError) ExtensionRegistry.unloadAll()
            failure(error)
        } finally {
            runCatching { PreferenceFiles.flushDirty() }
        }

    private fun dispatch(
        op: Int,
        reader: WireReader,
        writer: WireWriter,
    ) {
        when (op) {
            INIT -> init(reader, writer)
            LOAD -> SourceCalls.load(reader, writer)
            POPULAR -> SourceCalls.popular(reader, writer)
            LATEST -> SourceCalls.latest(reader, writer)
            SEARCH -> SourceCalls.search(reader, writer)
            FILTERS -> SourceCalls.filters(reader, writer)
            DETAILS -> SourceCalls.details(reader, writer)
            CHAPTERS -> SourceCalls.chapters(reader, writer)
            PAGES -> SourceCalls.pages(reader, writer)
            IMAGE -> SourceCalls.image(reader, writer)
            PREFERENCES -> SourceCalls.preferences(reader, writer)
            SET_PREFERENCE -> SourceCalls.setPreference(reader, writer)
            UNLOAD -> {
                val packageName = reader.requireString()
                val purge = reader.bool()
                ExtensionRegistry.unload(packageName, purge)
            }
            TRIM -> {
                ExtensionRegistry.unloadAll()
                System.gc()
            }
            else -> throw IllegalArgumentException("unknown host operation $op")
        }
    }

    /** Boots the host once per JVM. Replies with the wire protocol and host versions. */
    private fun init(
        reader: WireReader,
        writer: WireWriter,
    ) {
        val config =
            HostConfig(
                dataDir = File(reader.requireString()),
                cacheDir = File(reader.requireString()),
                userAgent = reader.requireString(),
            )
        if (!Host.isBooted) {
            NativeNetInterceptor.verifyOkHttpLayout()
            verifyPatchedConverter()
            Host.boot(config, NativeHostServices())
        }
        writer.i32(HostVersion.PROTOCOL).string(HostVersion.NAME)
    }

    /** The patched NewTransformer must shadow dex2jar's (see ConstructorFixups). */
    private fun verifyPatchedConverter() {
        val patched = Class.forName("com.googlecode.dex2jar.ir.ts.NewTransformer").protectionDomain.codeSource?.location
        val host = Bridge::class.java.protectionDomain.codeSource?.location
        check(patched == host) { "dex2jar's NewTransformer shadows the host's patched copy ($patched)" }
    }

    private fun failure(error: Throwable): ByteArray {
        val root = generateSequence(error) { it.cause?.takeIf { cause -> cause !== it } }.last()
        val message =
            buildString {
                append(error.message ?: error.javaClass.simpleName)
                if (root !== error && root.message != null && root.message != error.message) {
                    append(" (caused by ").append(root.javaClass.simpleName).append(": ").append(root.message).append(')')
                }
            }
        return WireWriter().u8(1).string(error.javaClass.name).string(message).toByteArray()
    }
}
