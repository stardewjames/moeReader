package moe.reader.suwayomi

import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import moe.reader.suwayomi.net.NativeNetInterceptor
import okhttp3.Authenticator
import okhttp3.OkHttpClient
import eu.kanade.tachiyomi.network.NetworkHelper
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import okhttp3.Request
import java.lang.reflect.Method
import java.util.concurrent.locks.ReentrantLock

/**
 * The source operations the app calls. Each runs on the calling (app worker)
 * thread; suspend entry points are driven with runBlocking under a deadline,
 * so a source that never completes releases the thread instead of pinning it.
 */
object SourceCalls {
    /** Wall-clock budget of one source operation. */
    private const val OPERATION_TIMEOUT_MILLIS = 90_000L

    /**
     * Extensions may reject a second concurrent `getMangaUpdate` for one manga
     * with `IllegalStateException`. The app asks for details and chapters at
     * the same time, so the host runs them one after the other: the extension's
     * threading contract is enforced here, once, for every app caller. Striped
     * locks keep the memory bounded, and they are reentrant because a source
     * may call its own update while parsing.
     */
    private val mangaLocks = Array(32) { ReentrantLock() }

    private fun <T> SourceState.forManga(
        url: String,
        block: () -> T,
    ): T {
        val hash = System.identityHashCode(this) * 31 xor url.hashCode()
        val lock = mangaLocks[(hash and Int.MAX_VALUE) % mangaLocks.size]
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }

    private fun <T> await(block: suspend () -> T): T = runBlocking { withTimeout(OPERATION_TIMEOUT_MILLIS) { block() } }

    // MARK: Loading

    fun load(
        reader: WireReader,
        writer: WireWriter,
    ) {
        val header = ExtensionHeader.read(reader)
        ExtensionRegistry.use(header) { extension ->
            writer.list(extension.sources) { state ->
                val source = state.source
                i64(source.id)
                string(source.name)
                string(source.lang)
                bool(source.supportsLatest)
                bool(isNsfw(source))
                bool(source is eu.kanade.tachiyomi.source.ConfigurableSource)
                val headers = (source as? HttpSource)?.headers
                i32(headers?.size ?: 0)
                if (headers != null) {
                    for (index in 0 until headers.size) {
                        string(headers.name(index))
                        string(headers.value(index))
                    }
                }
            }
        }
    }

    /** The pre-1.4 `@Nsfw` class annotation; newer extensions flag NSFW in the repository index. */
    private fun isNsfw(source: CatalogueSource): Boolean = source.javaClass.annotations.any { it.annotationClass.java.simpleName == "Nsfw" }

    private inline fun <T> withSource(
        reader: WireReader,
        crossinline body: (LoadedExtension, SourceState) -> T,
    ): T {
        val header = ExtensionHeader.read(reader)
        val sourceId = reader.i64()
        return ExtensionRegistry.use(header) { extension -> body(extension, extension.source(sourceId)) }
    }

    // MARK: Listings

    fun popular(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val page = reader.i32()
        writeMangas(writer, state, await { state.source.getPopularManga(page) })
    }

    fun latest(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val page = reader.i32()
        writeMangas(writer, state, await { state.source.getLatestUpdates(page) })
    }

    fun search(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val query = reader.requireString()
        val page = reader.i32()
        val selections = Filters.readSelections(reader)
        val filters = state.source.getFilterList()
        Filters.apply(filters, selections)
        writeMangas(writer, state, await { state.source.getSearchManga(page, query, filters) })
    }

    fun filters(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        Filters.write(writer, state.source.getFilterList())
    }

    private fun writeMangas(
        writer: WireWriter,
        state: SourceState,
        page: MangasPage,
    ) {
        // A manga without a url cannot be opened: drop it instead of sending
        // the app a dead entry it cannot resolve later.
        val mangas = page.mangas.filter { it.urlOrEmpty().isNotEmpty() }
        if (mangas.size != page.mangas.size) {
            Host.services.log(
                HostServices.LOG_WARN,
                "listing: dropped ${page.mangas.size - mangas.size} entries without a url",
            )
        }
        writer.bool(page.hasNextPage)
        writer.list(mangas) { manga ->
            state.remember(manga)
            writeManga(this, manga)
        }
    }

    private fun writeManga(
        writer: WireWriter,
        manga: SManga,
    ) {
        writer
            .string(manga.urlOrEmpty())
            .string(manga.titleOrEmpty())
            .string(manga.thumbnail_url)
            .string(manga.description)
            .string(manga.author)
            .string(manga.artist)
            .i32(manga.status)
            .strings(manga.getGenres().orEmpty())
    }

    // MARK: Details and chapters

    fun details(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val url = reader.requireString()
        val title = reader.string()
        val manga = state.manga(url, title)
        val update = state.forManga(url) {
            await { state.source.getMangaUpdate(manga, emptyList(), true, false) }
        }
        val result = update.manga
        // A source may answer with a model it only partly filled; the app's
        // request is the fallback for both the identity and the title.
        if (result.urlOrEmpty().isEmpty()) result.url = url
        if (result.titleOrEmpty().isEmpty() && !title.isNullOrEmpty()) result.title = title
        state.remember(result)
        writeManga(writer, result)
    }

    fun chapters(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val url = reader.requireString()
        val title = reader.string()
        val manga = state.manga(url, title)
        // Mihon's chapter refresh: details are not parsed a second time.
        val update = state.forManga(url) {
            await { state.source.getMangaUpdate(manga, emptyList(), false, true) }
        }
        val chapters = update.chapters.filter { it.urlOrEmpty().isNotEmpty() }
        if (chapters.size != update.chapters.size) {
            Host.services.log(
                HostServices.LOG_WARN,
                "chapters: dropped ${update.chapters.size - chapters.size} entries without a url",
            )
        }
        writer.list(chapters) { chapter ->
            state.remember(chapter)
            writeChapter(this, chapter)
        }
    }

    private fun writeChapter(
        writer: WireWriter,
        chapter: SChapter,
    ) {
        writer
            .string(chapter.urlOrEmpty())
            .string(chapter.nameOrEmpty())
            .f64(chapter.chapter_number.toDouble())
            .string(chapter.scanlator)
            .i64(chapter.date_upload)
    }

    // MARK: Pages

    private fun pagesFor(
        state: SourceState,
        chapterUrl: String,
        chapterName: String?,
    ): List<Page> {
        state.pages(chapterUrl)?.let { return it }
        val chapter = state.chapter(chapterUrl, chapterName)
        val pages = await { state.source.getPageList(chapter) }
        state.rememberPages(chapterUrl, pages)
        return pages
    }

    /** Image URLs are resolved lazily, per page, when the reader asks for it. */
    fun pages(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val chapterUrl = reader.requireString()
        val chapterName = reader.string()
        val pages = pagesFor(state, chapterUrl, chapterName)
        writer.list(pages) { page ->
            string(page.url)
            string(page.imageUrl)
        }
    }

    /**
     * Bytes of one page, or, when the source's client adds nothing to a plain
     * request, the request itself so the app downloads it without the JVM.
     * Replies: u8 0 + contentType + bytes, or u8 1 + url + method + headers.
     */
    fun image(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        val chapterUrl = reader.requireString()
        val chapterName = reader.string()
        val pageIndex = reader.i32()
        val allowDirect = reader.bool()
        val source = state.source as? HttpSource ?: throw UnsupportedOperationException("${state.source.name} is not an HTTP source")
        val pages = pagesFor(state, chapterUrl, chapterName)
        // Positional, like the list the app received: Page.index is not
        // reliable across sources ("the index is ignored" in Source.getPageList).
        val page = pages.getOrNull(pageIndex) ?: throw IndexOutOfBoundsException("page $pageIndex of ${pages.size}")
        if (page.imageUrl.isNullOrEmpty()) {
            page.imageUrl = await { source.getImageUrl(page) }
        }
        if (allowDirect && state.isPlainClient()) {
            val request = imageRequest(source, page)
            if (request.method == "GET" && request.body == null) {
                val headers = ArrayList<Pair<String, String>>(request.headers.size + 1)
                for (index in 0 until request.headers.size) headers += request.headers.name(index) to request.headers.value(index)
                if (headers.none { it.first.equals("User-Agent", ignoreCase = true) }) headers += "User-Agent" to Host.config.userAgent
                writer.u8(1).string(request.url.toString()).string(request.method)
                writer.list(headers) { (name, value) ->
                    string(name)
                    string(value)
                }
                return@withSource
            }
        }
        await { source.getImage(page) }.use { response ->
            if (!response.isSuccessful) throw java.io.IOException("HTTP error ${response.code}")
            val body = response.body
            val contentType = body.contentType()?.toString()
            val bytes = body.bytes()
            writer.u8(0).string(contentType).bytes(bytes)
        }
    }

    private val imageRequestMethod: Method by lazy {
        HttpSource::class.java.getDeclaredMethod("imageRequest", Page::class.java).apply { isAccessible = true }
    }

    private fun imageRequest(
        source: HttpSource,
        page: Page,
    ): Request = imageRequestMethod.invoke(source, page) as Request

    /**
     * True when the client is the host's base client plus nothing that could
     * change an image request or its bytes: only the host's own interceptors,
     * no network interceptors, default redirects and no authenticator. Rate
     * limiters count as additions, so their throttling is never bypassed.
     */
    internal fun isPlainClient(client: OkHttpClient): Boolean =
        client.networkInterceptors.isEmpty() &&
            client.followRedirects &&
            client.authenticator == Authenticator.NONE &&
            client.followSslRedirects &&
            client.cookieJar === Injekt.get<NetworkHelper>().client.cookieJar &&
            client.interceptors.all {
                it is NativeNetInterceptor ||
                    it is UncaughtExceptionInterceptor ||
                    it is UserAgentInterceptor ||
                    it is CloudflareInterceptor
            }

    // MARK: Preferences

    fun preferences(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { _, state ->
        Preferences.write(writer, Preferences.screen(state.source))
    }

    fun setPreference(
        reader: WireReader,
        writer: WireWriter,
    ) = withSource(reader) { extension, state ->
        val key = reader.requireString()
        val value = reader.requireString()
        val values = reader.strings()
        val changed = Preferences.set(state.source, key, value, values)
        // Sources read preferences when constructed; rebuild them.
        if (changed) extension.recreateSources()
        writer.bool(changed)
    }
}
