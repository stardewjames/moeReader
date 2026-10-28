package moe.reader.suwayomi

import eu.kanade.tachiyomi.source.CatalogueSource
import java.io.File
import java.util.zip.ZipOutputStream
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertTrue

class RegistryFixtureSource : CatalogueSource {
    override val id = 17L
    override val name = "Registry fixture"
    override val lang = "en"
    override val supportsLatest = false
}

class ExtensionRegistryTest {
    @BeforeTest
    fun boot() {
        TestHost.boot()
        ExtensionRegistry.unloadAll()
    }

    private fun cached(packageName: String, key: String): Pair<ExtensionHeader, File> {
        val header = ExtensionHeader(packageName, "unused.apk", key, listOf(RegistryFixtureSource::class.java.name))
        val jar = File(Host.config.dataDir, "jars/$packageName-$key-c${HostVersion.CONVERTER}.jar")
        jar.parentFile.mkdirs()
        // The test fixture class is found by the parent loader. No APK conversion or network.
        ZipOutputStream(jar.outputStream()).use { }
        return header to jar
    }

    @Test
    fun purgeWaitsForTheActiveCallAndDoesNotReuseItsLoader() {
        val (header, jar) = cached("fixture.purge", "one")
        ExtensionRegistry.use(header) { active ->
            ExtensionRegistry.unload(header.packageName, purge = true)
            assertEquals(0, ExtensionRegistry.residentCount)
            assertTrue(jar.exists(), "an in-flight loader may still need classes from this jar")
            assertEquals("Registry fixture", active.source(17).source.name)
        }
        assertFalse(jar.exists(), "purge completes when the last active call releases the loader")
    }

    @Test
    fun switchingDropsBusySourcesAfterReleaseButKeepsTheConversionCache() {
        val (header, jar) = cached("fixture.switch", "one")
        lateinit var previous: LoadedExtension
        ExtensionRegistry.use(header) { active ->
            previous = active
            ExtensionRegistry.unloadAll()
            assertEquals(0, ExtensionRegistry.residentCount)
            assertEquals("Registry fixture", active.source(17).source.name)
        }
        assertTrue(jar.exists(), "switching engines must not force another dex conversion")
        ExtensionRegistry.use(header) { next ->
            assertNotSame(previous, next)
            assertEquals("Registry fixture", next.source(17).source.name)
        }
        ExtensionRegistry.unload(header.packageName, purge = true)
    }

    @Test
    fun anUpdateKeepsTheOldJarUntilItsLastCallFinishes() {
        val (old, oldJar) = cached("fixture.update", "old")
        lateinit var newJar: File
        ExtensionRegistry.use(old) { previous ->
            val (new, jar) = cached("fixture.update", "new")
            newJar = jar
            ExtensionRegistry.use(new) { replacement ->
                assertNotSame(previous, replacement)
                assertTrue(oldJar.exists())
                assertTrue(newJar.exists())
            }
            assertTrue(oldJar.exists())
        }
        assertFalse(oldJar.exists())
        assertTrue(newJar.exists())
        ExtensionRegistry.unload(old.packageName, purge = true)
    }
}
