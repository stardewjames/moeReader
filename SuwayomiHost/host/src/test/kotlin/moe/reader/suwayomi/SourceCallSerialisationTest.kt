package moe.reader.suwayomi

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipOutputStream
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A source that rejects a second concurrent `getMangaUpdate` for one manga,
 * which some extensions do with `IllegalStateException`.
 */
class SerialisedFixtureSource : CatalogueSource {
    override val id = 42L
    override val name = "Serialisation fixture"
    override val lang = "en"
    override val supportsLatest = false

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        check(inFlight.putIfAbsent(manga.url, true) == null) {
            overlaps.incrementAndGet()
            "getMangaUpdate must not be called concurrently for same manga"
        }
        try {
            Thread.sleep(200)
            val updated = SManga.create().also {
                it.url = manga.url
                it.title = manga.title.ifEmpty { "Fixture" }
            }
            return SMangaUpdate(updated, if (fetchChapters) emptyList() else emptyList())
        } finally {
            inFlight.remove(manga.url)
        }
    }

    companion object {
        private val inFlight = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
        val overlaps = AtomicInteger()
    }
}

class SourceCallSerialisationTest {
    @BeforeTest
    fun boot() {
        TestHost.boot()
        ExtensionRegistry.unloadAll()
        SerialisedFixtureSource.overlaps.set(0)
    }

    private fun header(key: String): ExtensionHeader {
        val name = "fixture.serialised"
        // A cached, empty jar: the fixture class comes from the test class loader.
        File(Host.config.dataDir, "jars/$name-$key-c${HostVersion.CONVERTER}.jar").apply {
            parentFile.mkdirs()
            ZipOutputStream(outputStream()).use { }
        }
        return ExtensionHeader(name, "unused.apk", key, listOf(SerialisedFixtureSource::class.java.name))
    }

    @Test
    fun detailsAndChaptersForOneMangaRunOneAfterTheOther() {
        val extension = header("one")
        val failures = ConcurrentLinkedQueue<Throwable>()
        val start = CountDownLatch(1)
        val threads = listOf(Bridge.DETAILS, Bridge.CHAPTERS).map { op ->
            Thread {
                start.await()
                try {
                    TestHost.call(op) {
                        string(extension.packageName)
                        string(extension.apkPath)
                        string(extension.apkKey)
                        strings(extension.classNames)
                        i64(SerialisedFixtureSource().id)
                        string("https://example.test/manga/1")
                        string("Example")
                    }
                } catch (error: Throwable) {
                    failures += error
                }
            }.apply { isDaemon = true }
        }
        threads.forEach { it.start() }
        start.countDown()
        threads.forEach { it.join(30_000) }

        assertTrue(failures.isEmpty(), failures.joinToString("\n") { it.toString() })
        assertEquals(0, SerialisedFixtureSource.overlaps.get(), "the extension saw two concurrent updates")
    }

    @Test
    fun differentMangaBothAnswer() {
        val extension = header("two")
        val results = ConcurrentLinkedQueue<String>()
        val start = CountDownLatch(1)
        val threads = listOf(1, 2).map { index ->
            Thread {
                start.await()
                val reply = TestHost.call(Bridge.DETAILS) {
                    string(extension.packageName)
                    string(extension.apkPath)
                    string(extension.apkKey)
                    strings(extension.classNames)
                    i64(SerialisedFixtureSource().id)
                    string("https://example.test/manga/$index")
                    string("Example $index")
                }
                results += reply.requireString()
            }.apply { isDaemon = true }
        }
        threads.forEach { it.start() }
        start.countDown()
        threads.forEach { it.join(30_000) }

        assertEquals(2, results.size, "both lookups answered")
        assertEquals(setOf("https://example.test/manga/1", "https://example.test/manga/2"), results.toSet())
        assertEquals(0, SerialisedFixtureSource.overlaps.get())
    }
}
