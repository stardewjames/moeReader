package moe.reader.suwayomi

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue

/**
 * Opt-in audit over a directory of extension APKs: every package is converted,
 * loaded, every source instantiated and its filter list built. This is the
 * offline half of the app-side surface (dex2jar, class loading, the Android and
 * Java APIs a source touches while constructing), so it reports failures
 * without needing the sites.
 *
 * `SUWAYOMI_TEST_APK_DIR=/path/to/apks ./gradlew :host:test`.
 * Directories and APKs stay out of the repository.
 */
class ExtensionSweepTest {
    @Test
    fun loadsEveryApkInTheDirectory() {
        val directory = System.getenv("SUWAYOMI_TEST_APK_DIR")
        assumeTrue(directory != null, "set SUWAYOMI_TEST_APK_DIR to audit a directory of extension APKs")
        TestHost.boot()
        val apks =
            File(directory!!)
                .listFiles { file -> file.isFile && file.extension == "apk" }
                .orEmpty()
                .sortedBy { it.name }
        assumeTrue(apks.isNotEmpty(), "no .apk files in SUWAYOMI_TEST_APK_DIR")

        val failures = LinkedHashMap<String, String>()
        for (apk in apks) {
            try {
                val header = TestHost.headerFor(apk)
                val sources =
                    TestHost.call(Bridge.LOAD) { writeHeader(header) }
                        .list {
                            val id = i64()
                            val name = requireString()
                            val lang = requireString()
                            bool()
                            bool()
                            bool()
                            list { requireString() to requireString() }
                            Triple(id, name, lang)
                        }
                check(sources.isNotEmpty()) { "the extension declares no sources" }
                for ((id, _, _) in sources) {
                    TestHost.call(Bridge.FILTERS) {
                        writeHeader(header)
                        i64(id)
                    }
                }
            } catch (error: Throwable) {
                failures[apk.name] = "${error::class.java.simpleName}: ${error.message}"
            }
        }

        println("extension sweep: ${apks.size - failures.size}/${apks.size} loaded")
        failures.forEach { (name, error) -> println("FAIL $name: $error") }
        assertTrue(failures.isEmpty(), failures.entries.joinToString("\n") { "${it.key}: ${it.value}" })
    }
}
