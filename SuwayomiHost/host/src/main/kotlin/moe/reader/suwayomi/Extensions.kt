package moe.reader.suwayomi

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.BaseDexExceptionHandler
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.MultiDexFileReader
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.model.SManga
import suwayomi.tachidesk.manga.impl.util.BytecodeEditor
import suwayomi.tachidesk.manga.impl.util.ChildFirstURLClassLoader
import java.io.File
import java.net.URL
import java.net.URLClassLoader
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** Identifies an installed extension; sent with every source call. */
class ExtensionHeader(
    val packageName: String,
    val apkPath: String,
    /** Content hash of the APK (the app stores packages as `<sha256>.apk`). */
    val apkKey: String,
    /** `tachiyomi.extension.class`, already resolved to fully-qualified names. */
    val classNames: List<String>,
) {
    companion object {
        fun read(reader: WireReader) =
            ExtensionHeader(
                packageName = reader.requireString(),
                apkPath = reader.requireString(),
                apkKey = reader.requireString(),
                classNames = reader.strings(),
            )
    }
}

/**
 * APK -> JAR conversion, once per APK content. The converted jar is cached
 * under the host's data directory and written with stored (uncompressed)
 * entries: the conversion pays for it once, and every later class load in
 * every session skips inflation.
 */
object ExtensionConverter {
    private val conversionLock = Any()

    fun jarFor(header: ExtensionHeader): File {
        val directory = File(Host.config.dataDir, "jars").apply { mkdirs() }
        val jar = File(directory, "${header.packageName}-${header.apkKey}-c${HostVersion.CONVERTER}.jar")
        if (jar.isFile) return jar
        synchronized(conversionLock) {
            if (jar.isFile) return jar
            val apk = File(header.apkPath)
            require(apk.isFile) { "installed package is missing: ${header.apkPath}" }
            val converted = File(directory, "${jar.name}.d2j")
            val packed = File(directory, "${jar.name}.tmp")
            try {
                val (_, constructors) = ConstructorFixups.collect { dex2jar(apk, converted) }
                BytecodeEditor.fixAndroidClasses(converted.toPath())
                repack(converted, apk, packed, constructors)
                check(packed.renameTo(jar)) { "cannot move converted jar into place" }
            } finally {
                converted.delete()
                packed.delete()
            }
            return jar
        }
    }

    /** Retains only jars still usable by a live loader (or the newly loaded APK). */
    fun prune(packageName: String, keepKeys: Set<String> = emptySet()) {
        synchronized(conversionLock) {
            val keepNames = keepKeys.mapTo(HashSet()) { "$packageName-$it-c${HostVersion.CONVERTER}.jar" }
            File(Host.config.dataDir, "jars").listFiles()?.forEach {
                if (it.name.startsWith("$packageName-") && it.name !in keepNames) it.delete()
            }
        }
    }

    /**
     * dex2jar with Suwayomi's settings (PackageTools.dex2jar). Like upstream,
     * a method dex2jar cannot translate becomes a throwing stub instead of
     * failing the whole extension; the count is logged.
     */
    private fun dex2jar(
        apk: File,
        jar: File,
    ) {
        val reader = MultiDexFileReader.open(apk.readBytes())
        val handler = CountingExceptionHandler()
        Dex2jar
            .from(reader)
            .withExceptionHandler(handler)
            .reUseReg(false)
            .topoLogicalSort()
            .skipDebug(true)
            .optimizeSynchronized(false)
            .printIR(false)
            .noCode(false)
            .skipExceptions(false)
            .dontSanitizeNames(true)
            .computeFrames(true)
            .to(jar.toPath())
        if (handler.failures > 0) {
            Host.services.log(HostServices.LOG_WARN, "dex2jar: ${handler.failures} methods of ${apk.name} could not be translated")
        }
    }

    private class CountingExceptionHandler : BaseDexExceptionHandler() {
        @Volatile var failures = 0

        override fun handleFileException(e: Exception) {
            failures += 1
            super.handleFileException(e)
        }

        override fun handleMethodTranslateException(
            method: Method,
            methodNode: DexMethodNode,
            mv: org.objectweb.asm.MethodVisitor,
            e: Exception,
        ) {
            failures += 1
            super.handleMethodTranslateException(method, methodNode, mv, e)
        }
    }

    /**
     * Writes classes (with the constructors dex2jar could not express, see
     * [ConstructorFixups]) and the APK's `assets/` (string bundles extensions
     * read through getResourceAsStream, as Suwayomi's extractAssetsFromApk
     * does) into one stored jar.
     */
    private fun repack(
        classes: File,
        apk: File,
        output: File,
        constructors: Map<String, List<ConstructorFixups.Needed>>,
    ) {
        ZipOutputStream(output.outputStream().buffered(1 shl 16)).use { out ->
            out.setMethod(ZipOutputStream.STORED)
            val seen = HashSet<String>()
            fun copy(
                zip: ZipFile,
                filter: (ZipEntry) -> Boolean,
            ) {
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (entry.isDirectory || !filter(entry) || !seen.add(entry.name)) continue
                    var bytes = zip.getInputStream(entry).use { it.readBytes() }
                    constructors[entry.name.removeSuffix(".class")]?.let { bytes = ConstructorFixups.addMissing(bytes, it) }
                    val crc = CRC32().apply { update(bytes) }
                    out.putNextEntry(
                        ZipEntry(entry.name).apply {
                            method = ZipEntry.STORED
                            size = bytes.size.toLong()
                            compressedSize = bytes.size.toLong()
                            this.crc = crc.value
                        },
                    )
                    out.write(bytes)
                    out.closeEntry()
                }
            }
            ZipFile(classes).use { zip -> copy(zip) { !it.name.startsWith("META-INF/") } }
            ZipFile(apk).use { zip -> copy(zip) { it.name.startsWith("assets/") } }
        }
    }
}

/** Per-source state the host keeps between calls. */
class SourceState(
    val source: CatalogueSource,
) {
    private val mangas = lruMap<String, SManga>(512)
    private val chapters = lruMap<String, SChapter>(2048)
    private val pageLists = lruMap<String, List<Page>>(4)

    @Volatile private var plainClient: Boolean? = null

    /** See [SourceCalls.isPlainClient]; computed once per source instance. */
    fun isPlainClient(): Boolean {
        plainClient?.let { return it }
        val http = source as? HttpSource ?: return false
        return SourceCalls.isPlainClient(http.client).also { plainClient = it }
    }

    /**
     * The manga object the source produced in a listing, so details and
     * chapter calls see every field it set (memo, thumbnail, initialized).
     */
    fun manga(
        url: String,
        title: String?,
    ): SManga =
        synchronized(mangas) { mangas[url] }?.also { cached ->
            if (!title.isNullOrEmpty()) cached.title = title
        } ?: SManga.create().also {
            it.url = url
            it.title = title.orEmpty()
        }

    fun remember(manga: SManga) {
        if (manga.url.isNotEmpty()) synchronized(mangas) { mangas[manga.url] = manga }
    }

    fun chapter(
        url: String,
        name: String?,
    ): SChapter =
        synchronized(chapters) { chapters[url] }?.also { cached ->
            if (!name.isNullOrEmpty()) cached.name = name
        } ?: SChapter.create().also {
            it.url = url
            it.name = name.orEmpty()
        }

    fun remember(chapter: SChapter) {
        if (chapter.url.isNotEmpty()) synchronized(chapters) { chapters[chapter.url] = chapter }
    }

    fun pages(chapterUrl: String): List<Page>? = synchronized(pageLists) { pageLists[chapterUrl] }

    fun rememberPages(
        chapterUrl: String,
        pages: List<Page>,
    ) {
        synchronized(pageLists) { pageLists[chapterUrl] = pages }
    }
}

private fun <K, V> lruMap(limit: Int): LinkedHashMap<K, V> =
    object : LinkedHashMap<K, V>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > limit
    }

/** One extension's class loader and source instances. */
class LoadedExtension(
    val header: ExtensionHeader,
    private val loader: URLClassLoader,
) {
    @Volatile private var states: Map<Long, SourceState> = instantiate()

    /** Calls in flight; the registry never closes a busy loader. */
    @Volatile var activeCalls = 0

    val sources: Collection<SourceState> get() = states.values

    fun source(id: Long): SourceState = states[id] ?: throw NoSuchElementException("source $id is not provided by ${header.packageName}")

    /**
     * Fresh source instances from the same classes. Sources read their
     * preferences when constructed, so a changed preference needs new ones
     * (Suwayomi unregisters the source for the same reason).
     */
    fun recreateSources() {
        states = instantiate()
    }

    private fun instantiate(): Map<Long, SourceState> {
        val result = LinkedHashMap<Long, SourceState>()
        for (className in header.classNames) {
            val instance = Class.forName(className, false, loader).getDeclaredConstructor().newInstance()
            val sources =
                when (instance) {
                    is SourceFactory -> instance.createSources()
                    is Source -> listOf(instance)
                    else -> throw IllegalStateException("$className is neither a Source nor a SourceFactory")
                }
            for (source in sources) {
                if (source is CatalogueSource) result[source.id] = SourceState(source)
            }
        }
        check(result.isNotEmpty()) { "${header.packageName} provides no catalogue sources" }
        return result
    }

    fun close() {
        runCatching { loader.close() }
    }

    companion object {
        fun load(header: ExtensionHeader): LoadedExtension {
            val jar = ExtensionConverter.jarFor(header)
            val loader = ChildFirstURLClassLoader(arrayOf<URL>(jar.toURI().toURL()))
            return try {
                LoadedExtension(header, loader)
            } catch (error: Throwable) {
                loader.close()
                throw error
            }
        }
    }
}

/**
 * Loaded extensions, least recently used first. At most [LIMIT] stay resident
 * so an idle reader holds few class loaders and source heaps; an extension in
 * use is never evicted, so the limit may be exceeded while calls run.
 */
object ExtensionRegistry {
    private const val LIMIT = 3

    private val loaded = LinkedHashMap<String, LoadedExtension>(8, 0.75f, true)
    // Fixed stripes keep package-loading locks bounded without serializing all conversions.
    private val loadLocks = Array(16) { Any() }
    private val retired = HashSet<LoadedExtension>()
    private val cachedKeys = HashMap<String, String>()
    private var generation = 0L

    private fun loadLock(packageName: String): Any = loadLocks[(packageName.hashCode() and Int.MAX_VALUE) % loadLocks.size]

    fun <T> use(
        header: ExtensionHeader,
        body: (LoadedExtension) -> T,
    ): T {
        val extension = acquire(header)
        try {
            return body(extension)
        } finally {
            synchronized(this) {
                extension.activeCalls -= 1
                if (extension.activeCalls == 0 && retired.remove(extension)) {
                    extension.close()
                    prune(extension.header.packageName)
                }
                trim()
            }
        }
    }

    private fun acquire(header: ExtensionHeader): LoadedExtension {
        synchronized(this) {
            current(header)?.let {
                it.activeCalls += 1
                return it
            }
        }
        synchronized(loadLock(header.packageName)) {
            synchronized(this) {
                current(header)?.let {
                    it.activeCalls += 1
                    return it
                }
            }
            val startedAt = synchronized(this) { generation }
            val fresh = LoadedExtension.load(header)
            synchronized(this) {
                loaded.remove(header.packageName)?.let { retire(it) }
                fresh.activeCalls += 1
                if (generation == startedAt) loaded[header.packageName] = fresh else retired += fresh
                cachedKeys[header.packageName] = header.apkKey
                prune(header.packageName)
                return fresh
            }
        }
    }

    /** The resident extension for [header], or null when absent or built from another APK. */
    private fun current(header: ExtensionHeader): LoadedExtension? {
        val existing = loaded[header.packageName] ?: return null
        return if (existing.header.apkKey == header.apkKey && existing.header.classNames == header.classNames) existing else null
    }

    private fun trim() {
        val iterator = loaded.entries.iterator()
        var excess = loaded.size - LIMIT
        while (excess > 0 && iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.value.activeCalls == 0) {
                entry.value.close()
                iterator.remove()
                excess -= 1
            }
        }
    }

    private fun retire(extension: LoadedExtension) {
        if (extension.activeCalls == 0) extension.close() else retired += extension
    }

    /** Only called with the registry monitor held; busy retired loaders keep their jar. */
    private fun prune(packageName: String) {
        val keys = HashSet<String>()
        cachedKeys[packageName]?.let { keys += it }
        loaded[packageName]?.let { keys += it.header.apkKey }
        for (extension in retired) {
            if (extension.header.packageName == packageName) keys += extension.header.apkKey
        }
        ExtensionConverter.prune(packageName, keys)
    }

    fun unload(packageName: String, purge: Boolean = false) {
        synchronized(loadLock(packageName)) {
            synchronized(this) {
                loaded.remove(packageName)?.let { retire(it) }
                // For a plain unload, keep the newest cached jar for next use.
                // Purges wait for any in-flight calls to release their loaders.
                if (purge) {
                    cachedKeys.remove(packageName)
                    prune(packageName)
                }
            }
        }
    }

    /** Removes idle loaders now; in-flight calls close theirs on release. */
    fun unloadAll() {
        synchronized(this) {
            generation += 1
            loaded.values.forEach { retire(it) }
            loaded.clear()
        }
    }

    val residentCount: Int get() = synchronized(this) { loaded.size }
}
