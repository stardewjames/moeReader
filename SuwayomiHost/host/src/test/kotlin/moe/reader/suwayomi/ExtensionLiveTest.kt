package moe.reader.suwayomi

import net.dongliu.apk.parser.ApkFile
import java.io.File
import java.security.MessageDigest
import kotlin.system.measureTimeMillis
import kotlin.test.Test
import kotlin.test.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue

/**
 * Opt-in: runs one real extension through every host operation against its
 * live site, through the same Bridge entry point and wire format the app
 * uses. `SUWAYOMI_TEST_APK=/path/to/extension.apk ./gradlew :host:test`.
 * APKs and site names never enter the repository.
 */
class ExtensionLiveTest {
    @Test
    fun runsAnExtensionEndToEnd() {
        val path = System.getenv("SUWAYOMI_TEST_APK")
        assumeTrue(path != null, "set SUWAYOMI_TEST_APK to run the live extension check")
        TestHost.boot()
        val apk = File(path!!)
        val (packageName, classNames) =
            ApkFile(apk).use { parsed ->
                val pkg = parsed.apkMeta.packageName
                val raw =
                    Regex("""android:name="tachiyomi\.extension\.class"\s+android:value="([^"]+)"""")
                        .find(parsed.manifestXml)
                        ?.groupValues
                        ?.get(1) ?: error("no extension class metadata")
                pkg to raw.split(';').map { if (it.startsWith(".")) pkg + it else it }
            }
        val key = MessageDigest.getInstance("SHA-256").digest(apk.readBytes()).joinToString("") { "%02x".format(it) }
        fun WireWriter.header() {
            string(packageName)
            string(apk.absolutePath)
            string(key)
            strings(classNames)
        }

        var sourceId = 0L
        val load =
            measureTimeMillis {
                val reply = TestHost.call(Bridge.LOAD) { header() }
                val sources =
                    reply.list {
                        val id = i64()
                        val name = requireString()
                        val lang = requireString()
                        bool()
                        bool()
                        bool()
                        list { requireString() to requireString() }
                        Triple(id, name, lang)
                    }
                assertTrue(sources.isNotEmpty())
                val chosen = sources.firstOrNull { it.third == "en" } ?: sources.first()
                sourceId = chosen.first
                println("source: ${chosen.second} (${chosen.third}) of ${sources.size}")
            }
        println("load (conversion + class loading): $load ms")

        var mangaUrl = ""
        var mangaTitle = ""
        println(
            "popular: " +
                measureTimeMillis {
                    val page = TestHost.call(Bridge.POPULAR) {
                        header()
                        i64(sourceId)
                        i32(1)
                    }
                    page.bool()
                    val count = page.i32()
                    assertTrue(count > 0, "popular returned no titles")
                    mangaUrl = page.requireString()
                    mangaTitle = page.requireString()
                    println("first title: $mangaTitle ($count on page 1)")
                } + " ms",
        )

        val details = TestHost.call(Bridge.DETAILS) {
            header()
            i64(sourceId)
            string(mangaUrl)
            string(mangaTitle)
        }
        details.requireString()
        println("details title: ${details.requireString()}")

        val chapters = TestHost.call(Bridge.CHAPTERS) {
            header()
            i64(sourceId)
            string(mangaUrl)
            string(mangaTitle)
        }
        val chapterCount = chapters.i32()
        assertTrue(chapterCount > 0, "no chapters")
        val chapterUrl = chapters.requireString()
        val chapterName = chapters.requireString()
        println("chapters: $chapterCount, first: $chapterName")

        val pages = TestHost.call(Bridge.PAGES) {
            header()
            i64(sourceId)
            string(chapterUrl)
            string(chapterName)
        }
        val pageCount = pages.i32()
        assertTrue(pageCount > 0, "no pages")
        println("pages: $pageCount")

        // Whether page images can skip the JVM depends on what the client adds.
        val client =
            ExtensionRegistry.use(ExtensionHeader(packageName, apk.absolutePath, key, classNames)) {
                (it.source(sourceId).source as? eu.kanade.tachiyomi.source.online.HttpSource)?.client
            }
        println(
            "client interceptors: ${client?.interceptors?.map { it.javaClass.name }}, " +
                "network: ${client?.networkInterceptors?.map { it.javaClass.name }}",
        )

        for (allowDirect in listOf(true, false)) {
            val image = TestHost.call(Bridge.IMAGE) {
                header()
                i64(sourceId)
                string(chapterUrl)
                string(chapterName)
                i32(0)
                bool(allowDirect)
            }
            when (image.u8()) {
                1 -> println("image (direct allowed): plain request ${image.requireString()}")
                else -> {
                    image.string()
                    val bytes = image.bytes() ?: ByteArray(0)
                    assertTrue(bytes.size > 100, "image too small: ${bytes.size}")
                    println("image (through host, direct=$allowDirect): ${bytes.size} bytes")
                }
            }
        }
    }
}
