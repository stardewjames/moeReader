package moe.reader.suwayomi

import java.io.File
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
        val header = TestHost.headerFor(apk)

        var sourceId = 0L
        val load =
            measureTimeMillis {
                val reply = TestHost.call(Bridge.LOAD) { writeHeader(header) }
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
                        writeHeader(header)
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
            writeHeader(header)
            i64(sourceId)
            string(mangaUrl)
            string(mangaTitle)
        }
        details.requireString()
        println("details title: ${details.requireString()}")

        val chapters = TestHost.call(Bridge.CHAPTERS) {
            writeHeader(header)
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
            writeHeader(header)
            i64(sourceId)
            string(chapterUrl)
            string(chapterName)
        }
        val pageCount = pages.i32()
        assertTrue(pageCount > 0, "no pages")
        println("pages: $pageCount")

        // Whether page images can skip the JVM depends on what the client adds.
        val client =
            ExtensionRegistry.use(header) {
                (it.source(sourceId).source as? eu.kanade.tachiyomi.source.online.HttpSource)?.client
            }
        println(
            "client interceptors: ${client?.interceptors?.map { it.javaClass.name }}, " +
                "network: ${client?.networkInterceptors?.map { it.javaClass.name }}",
        )

        for (allowDirect in listOf(true, false)) {
            val image = TestHost.call(Bridge.IMAGE) {
                writeHeader(header)
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
