package moe.reader.suwayomi

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import java.io.File
import java.util.zip.ZipOutputStream
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Sources answer with `SManga.create()`/`SChapter.create()` — `SMangaImpl` and
 * `SChapterImpl`, whose `url`, `title` and `name` are `lateinit`. A source that
 * leaves one unset must not fail the call.
 */
class UnsetFieldsFixtureSource : CatalogueSource {
    override val id = 51L
    override val name = "Unset fields fixture"
    override val lang = "en"
    override val supportsLatest = false

    override suspend fun getPopularManga(page: Int): MangasPage =
        MangasPage(
            listOf(
                SManga.create().apply { title = "Listing without url" },
                SManga.create().apply {
                    url = "/manga/full"
                    title = "Complete listing"
                },
            ),
            hasNextPage = false,
        )

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        if (!fetchDetails) {
            return SMangaUpdate(
                manga,
                listOf(
                    SChapter.create().apply { url = "/chapter/1" },
                    SChapter.create().apply { name = "Chapter without url" },
                ),
            )
        }
        // Details that carry a title but no url, or a url but no title.
        val result =
            if (manga.url.endsWith("no-title")) {
                SManga.create().apply { url = manga.url }
            } else {
                SManga.create().apply { title = "Details title only" }
            }
        return SMangaUpdate(result, emptyList())
    }
}

class UnsetExtensionFieldsTest {
    @BeforeTest
    fun boot() {
        TestHost.boot()
        ExtensionRegistry.unloadAll()
    }

    private fun header(): ExtensionHeader {
        val name = "fixture.unset"
        File(Host.config.dataDir, "jars/$name-one-c${HostVersion.CONVERTER}.jar").apply {
            parentFile.mkdirs()
            ZipOutputStream(outputStream()).use { }
        }
        return ExtensionHeader(name, "unused.apk", "one", listOf(UnsetFieldsFixtureSource::class.java.name))
    }

    private fun WireWriter.header(extension: ExtensionHeader) {
        string(extension.packageName)
        string(extension.apkPath)
        string(extension.apkKey)
        strings(extension.classNames)
        i64(UnsetFieldsFixtureSource().id)
    }

    @Test
    fun listingWithoutUrlStillAnswers() {
        val extension = header()
        val reply = TestHost.call(Bridge.POPULAR) {
            header(extension)
            i32(1)
        }
        reply.bool()
        assertEquals(1, reply.i32(), "an entry without a url cannot be opened, so it is dropped")
        assertEquals("/manga/full", reply.requireString())
        assertEquals("Complete listing", reply.requireString())
    }

    @Test
    fun detailsFallBackToTheRequestWhenTheSourceOmitsFields() {
        val extension = header()
        val reply = TestHost.call(Bridge.DETAILS) {
            header(extension)
            string("/manga/1")
            string("Requested title")
        }
        assertEquals("/manga/1", reply.requireString(), "missing url falls back to the request")
        assertEquals("Details title only", reply.requireString())
    }

    @Test
    fun detailsFallBackToTheRequestedTitle() {
        val extension = header()
        val reply = TestHost.call(Bridge.DETAILS) {
            header(extension)
            string("/manga/no-title")
            string("Requested title")
        }
        assertEquals("/manga/no-title", reply.requireString())
        assertEquals("Requested title", reply.requireString(), "missing title falls back to the request")
    }

    @Test
    fun chaptersWithoutUrlAreDroppedAndNamesDefaultToEmpty() {
        val extension = header()
        val reply = TestHost.call(Bridge.CHAPTERS) {
            header(extension)
            string("/manga/1")
            string("Requested title")
        }
        assertEquals(1, reply.i32(), "a chapter without a url cannot be opened, so it is dropped")
        assertEquals("/chapter/1", reply.requireString())
        assertEquals("", reply.requireString(), "a missing name reads as empty")
        assertTrue(reply.f64().isFinite())
        assertEquals(null, reply.string())
        assertEquals(0L, reply.i64())
    }
}
