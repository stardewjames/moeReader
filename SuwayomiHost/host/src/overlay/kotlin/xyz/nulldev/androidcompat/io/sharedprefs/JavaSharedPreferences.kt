package xyz.nulldev.androidcompat.io.sharedprefs

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of AndroidCompat's JavaSharedPreferences with
 * the same constructor and deleteAll(). Upstream stores java.util.Properties as
 * XML and runs a background saver thread per file. Here values are typed and
 * held in memory, and the file is a small binary snapshot:
 *  - commit() writes at once;
 *  - apply() only marks the file dirty; the host flushes dirty files after the
 *    source call that changed them (PreferenceFiles.flushDirty), so an
 *    extension that applies on every request costs one write per call and no
 *    thread wakes up between calls.
 */

import android.content.SharedPreferences
import moe.reader.suwayomi.WireReader
import moe.reader.suwayomi.WireWriter
import xyz.nulldev.androidcompat.util.SafePath
import xyz.nulldev.ts.config.ApplicationRootDir
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class JavaSharedPreferences(
    private val key: String,
) : SharedPreferences {
    private val file = File(File(ApplicationRootDir, "settings"), "${SafePath.buildValidFilename(key)}.prefs")
    private val values = HashMap<String, Any>()
    private val listeners = LinkedHashSet<SharedPreferences.OnSharedPreferenceChangeListener>()

    init {
        if (file.isFile) {
            runCatching { read(file.readBytes()) }
        }
    }

    override fun getAll(): MutableMap<String, *> = synchronized(values) { HashMap(values) }

    override fun getString(
        key: String,
        defValue: String?,
    ): String? =
        when (val value = get(key)) {
            null -> defValue
            is Set<*> -> defValue
            else -> value.toString()
        }

    override fun getStringSet(
        key: String,
        defValues: MutableSet<String>?,
    ): MutableSet<String>? {
        @Suppress("UNCHECKED_CAST")
        return (get(key) as? Set<String>)?.toMutableSet() ?: defValues
    }

    override fun getInt(
        key: String,
        defValue: Int,
    ): Int = number(key)?.toInt() ?: defValue

    override fun getLong(
        key: String,
        defValue: Long,
    ): Long = number(key)?.toLong() ?: defValue

    override fun getFloat(
        key: String,
        defValue: Float,
    ): Float = number(key)?.toFloat() ?: defValue

    override fun getBoolean(
        key: String,
        defValue: Boolean,
    ): Boolean =
        when (val value = get(key)) {
            is Boolean -> value
            is String -> value.toBooleanStrictOrNull() ?: defValue
            else -> defValue
        }

    override fun contains(key: String): Boolean = synchronized(values) { key in values }

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        synchronized(listeners) { listeners += listener }
    }

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        synchronized(listeners) { listeners -= listener }
    }

    fun deleteAll(): Boolean {
        synchronized(values) { values.clear() }
        PreferenceFiles.forget(this)
        return !file.exists() || file.delete()
    }

    /** Writes the current snapshot; true on success. */
    internal fun writeNow(): Boolean {
        val bytes =
            synchronized(values) {
                val writer = WireWriter(64 + values.size * 32)
                writer.i32(values.size)
                for ((name, value) in values) {
                    writer.string(name)
                    when (value) {
                        is String -> writer.u8(TYPE_STRING).string(value)
                        is Set<*> -> writer.u8(TYPE_SET).strings(value.map { it.toString() })
                        is Int -> writer.u8(TYPE_INT).i32(value)
                        is Long -> writer.u8(TYPE_LONG).i64(value)
                        is Float -> writer.u8(TYPE_FLOAT).i32(value.toRawBits())
                        is Boolean -> writer.u8(TYPE_BOOLEAN).bool(value)
                        else -> writer.u8(TYPE_STRING).string(value.toString())
                    }
                }
                writer.toByteArray()
            }
        return runCatching {
            file.parentFile.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeBytes(bytes)
            if (!temporary.renameTo(file)) {
                file.delete()
                check(temporary.renameTo(file)) { "cannot replace $file" }
            }
        }.isSuccess
    }

    private fun read(bytes: ByteArray) {
        val reader = WireReader(bytes)
        val count = reader.i32()
        repeat(count) {
            val name = reader.requireString()
            val value: Any =
                when (val type = reader.u8()) {
                    TYPE_STRING -> reader.requireString()
                    TYPE_SET -> reader.strings().toSet()
                    TYPE_INT -> reader.i32()
                    TYPE_LONG -> reader.i64()
                    TYPE_FLOAT -> Float.fromBits(reader.i32())
                    TYPE_BOOLEAN -> reader.bool()
                    else -> error("unknown preference type $type")
                }
            values[name] = value
        }
    }

    private fun get(key: String): Any? = synchronized(values) { values[key] }

    private fun number(key: String): Number? =
        when (val value = get(key)) {
            is Number -> value
            is String -> value.toLongOrNull() ?: value.toDoubleOrNull()
            else -> null
        }

    private fun notify(changed: Collection<String>) {
        val snapshot = synchronized(listeners) { listeners.toList() }
        if (snapshot.isEmpty()) return
        for (name in changed) snapshot.forEach { it.onSharedPreferenceChanged(this, name) }
    }

    private inner class Editor : SharedPreferences.Editor {
        private val puts = LinkedHashMap<String, Any?>()
        private var clear = false

        override fun putString(
            key: String,
            value: String?,
        ) = put(key, value)

        override fun putStringSet(
            key: String,
            values: MutableSet<String>?,
        ) = put(key, values?.toSet())

        override fun putInt(
            key: String,
            value: Int,
        ) = put(key, value)

        override fun putLong(
            key: String,
            value: Long,
        ) = put(key, value)

        override fun putFloat(
            key: String,
            value: Float,
        ) = put(key, value)

        override fun putBoolean(
            key: String,
            value: Boolean,
        ) = put(key, value)

        override fun remove(key: String) = put(key, null)

        override fun clear(): SharedPreferences.Editor {
            clear = true
            return this
        }

        private fun put(
            key: String,
            value: Any?,
        ): SharedPreferences.Editor {
            puts[key] = value
            return this
        }

        /** Applies the edits in memory; returns the keys that changed. */
        private fun merge(): Collection<String> {
            val changed = LinkedHashSet<String>()
            synchronized(values) {
                if (clear) {
                    changed += values.keys
                    values.clear()
                }
                for ((name, value) in puts) {
                    if (value == null) {
                        if (values.remove(name) != null) changed += name
                    } else if (values.put(name, value) != value) {
                        changed += name
                    }
                }
            }
            return changed
        }

        override fun commit(): Boolean {
            val changed = merge()
            val written = changed.isEmpty() || writeNow()
            notify(changed)
            return written
        }

        override fun apply() {
            val changed = merge()
            if (changed.isNotEmpty()) PreferenceFiles.markDirty(this@JavaSharedPreferences)
            notify(changed)
        }
    }

    private companion object {
        const val TYPE_STRING = 0
        const val TYPE_SET = 1
        const val TYPE_INT = 2
        const val TYPE_LONG = 3
        const val TYPE_FLOAT = 4
        const val TYPE_BOOLEAN = 5
    }
}

/** Preference files changed with apply() and not yet written. */
object PreferenceFiles {
    private val dirty = ConcurrentHashMap.newKeySet<JavaSharedPreferences>()

    internal fun markDirty(preferences: JavaSharedPreferences) {
        dirty += preferences
    }

    internal fun forget(preferences: JavaSharedPreferences) {
        dirty -= preferences
    }

    /** Called by the host after every source call. A failed write stays dirty for the next flush. */
    fun flushDirty() {
        if (dirty.isEmpty()) return
        val pending = dirty.toList()
        dirty.removeAll(pending.toSet())
        for (preferences in pending) {
            if (!preferences.writeNow()) dirty += preferences
        }
    }
}
