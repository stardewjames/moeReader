package moe.reader.suwayomi

import xyz.nulldev.androidcompat.io.sharedprefs.JavaSharedPreferences
import xyz.nulldev.androidcompat.io.sharedprefs.PreferenceFiles
import xyz.nulldev.ts.config.ROOT_DIR_PROPERTY
import java.nio.file.Files
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SharedPreferencesTest {
    @BeforeTest
    fun root() {
        System.setProperty(ROOT_DIR_PROPERTY, Files.createTempDirectory("prefs").toString())
    }

    @Test
    fun applyIsWrittenAtTheNextFlushNotBefore() {
        val name = "source_apply"
        JavaSharedPreferences(name)
            .edit()
            .putString("mirror", "b")
            .putInt("pages", 3)
            .putLong("since", 1L shl 40)
            .putFloat("ratio", 1.5f)
            .putBoolean("hd", true)
            .putStringSet("langs", mutableSetOf("en", "ja"))
            .apply()
        assertNull(JavaSharedPreferences(name).getString("mirror", null), "apply() must not write synchronously")

        PreferenceFiles.flushDirty()
        val reloaded = JavaSharedPreferences(name)
        assertEquals("b", reloaded.getString("mirror", null))
        assertEquals(3, reloaded.getInt("pages", 0))
        assertEquals(1L shl 40, reloaded.getLong("since", 0))
        assertEquals(1.5f, reloaded.getFloat("ratio", 0f))
        assertTrue(reloaded.getBoolean("hd", false))
        assertEquals<Set<String>?>(setOf("en", "ja"), reloaded.getStringSet("langs", null))
    }

    @Test
    fun commitWritesImmediatelyAndRemovalsPersist() {
        val name = "source_commit"
        val preferences = JavaSharedPreferences(name)
        assertTrue(preferences.edit().putString("a", "1").putString("b", "2").commit())
        assertTrue(preferences.edit().remove("a").commit())
        val reloaded = JavaSharedPreferences(name)
        assertFalse(reloaded.contains("a"))
        assertEquals("2", reloaded.getString("b", null))
    }

    @Test
    fun numbersStoredAsTextReadAsNumbers() {
        // ListPreference stores strings; sources often read them back as ints.
        val preferences = JavaSharedPreferences("source_lenient")
        preferences.edit().putString("quality", "2").commit()
        assertEquals(2, preferences.getInt("quality", 0))
        assertEquals(7, preferences.getInt("missing", 7))
    }

    @Test
    fun listenersSeeChangedKeysOnly() {
        val preferences = JavaSharedPreferences("source_listeners")
        preferences.edit().putString("same", "x").commit()
        val changed = mutableListOf<String>()
        preferences.registerOnSharedPreferenceChangeListener { _, key -> changed += key.orEmpty() }
        preferences.edit().putString("same", "x").putString("new", "y").commit()
        assertEquals(listOf("new"), changed)
    }
}
