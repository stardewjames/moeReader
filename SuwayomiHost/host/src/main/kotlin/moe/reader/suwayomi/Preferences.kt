package moe.reader.suwayomi

import android.app.Application
import androidx.preference.DialogPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceScreen
import androidx.preference.TwoStatePreference
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.sourcePreferences
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * A source's preference screen, as Suwayomi's Source.getSourcePreferences
 * builds it, encoded for the app's settings sheet:
 *
 *   kind u8, key, title, summary, dialogTitle (strings),
 *   entries list, entryValues list, value string, values list
 */
object Preferences {
    const val HEADER = 0
    const val TEXT = 1
    const val LIST = 2
    const val MULTI_SELECT = 3
    const val TOGGLE = 4

    fun screen(source: Any): List<Preference> {
        if (source !is ConfigurableSource) return emptyList()
        val screen = PreferenceScreen(Injekt.get<Application>())
        screen.sharedPreferences = source.sourcePreferences()
        source.setupPreferenceScreen(screen)
        return screen.preferences
    }

    fun write(
        writer: WireWriter,
        preferences: List<Preference>,
    ) {
        val visible = preferences.filter { it.visible }
        writer.i32(visible.size)
        for (preference in visible) {
            val kind = kind(preference)
            val key = preference.key.orEmpty()
            var value = ""
            var values: List<String> = emptyList()
            var entries: List<String> = emptyList()
            var entryValues: List<String> = emptyList()
            when (preference) {
                is ListPreference -> {
                    entries = preference.entries.orEmpty().map { it.toString() }
                    entryValues = preference.entryValues.orEmpty().map { it.toString() }
                }
                is MultiSelectListPreference -> {
                    entries = preference.entries.orEmpty().map { it.toString() }
                    entryValues = preference.entryValues.orEmpty().map { it.toString() }
                }
            }
            if (kind != HEADER) {
                when (val current = runCatching { preference.currentValue }.getOrNull()) {
                    is Set<*> -> values = current.map { it.toString() }.sorted()
                    null -> Unit
                    else -> value = current.toString()
                }
            }
            writer
                .u8(kind)
                .string(key)
                .string(preference.title?.toString().orEmpty())
                .string(preference.summary?.toString())
                .string((preference as? DialogPreference)?.dialogTitle?.toString())
                .strings(entries)
                .strings(entryValues)
                .string(value)
                .strings(values)
        }
    }

    private fun kind(preference: Preference): Int =
        when {
            preference.key.isNullOrEmpty() -> HEADER
            preference is MultiSelectListPreference -> MULTI_SELECT
            preference is ListPreference -> LIST
            preference is TwoStatePreference -> TOGGLE
            preference is EditTextPreference -> TEXT
            else -> HEADER
        }

    /**
     * Saves one edited value the way Suwayomi's setSourcePreference does: store
     * it, then let the source's change listener react. Returns false when the
     * key is unknown or the control is disabled.
     */
    fun set(
        source: Any,
        key: String,
        value: String,
        values: List<String>,
    ): Boolean {
        val preference = screen(source).firstOrNull { it.key == key } ?: return false
        if (!preference.isEnabled) return false
        val newValue: Any =
            when (preference) {
                is MultiSelectListPreference -> values.toSet()
                is TwoStatePreference -> value == "true"
                else -> value
            }
        // saveNewValue keys on the default value's type, which some sources
        // leave unset; the value's own type decides then.
        runCatching { preference.saveNewValue(newValue) }.onFailure {
            val editor = preference.sharedPreferences.edit()
            @Suppress("UNCHECKED_CAST")
            when (newValue) {
                is Set<*> -> editor.putStringSet(key, newValue as Set<String>)
                is Boolean -> editor.putBoolean(key, newValue)
                else -> editor.putString(key, newValue.toString())
            }
            editor.apply()
        }
        preference.callChangeListener(newValue)
        return true
    }
}
