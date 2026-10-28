package xyz.nulldev.androidcompat.config

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of AndroidCompat's FilesConfigModule,
 * ApplicationInfoConfigModule and SystemConfigModule
 * (AndroidCompat/src/main/java/xyz/nulldev/androidcompat/config/). Same
 * properties and the defaults of compat-reference.conf, computed from the
 * host's root directory instead of read from HOCON.
 */

import xyz.nulldev.ts.config.ConfigModule

class FilesConfigModule(
    rootDir: String,
) : ConfigModule() {
    val rootDir: String = "$rootDir/appdata"
    val externalStorageDir: String = "$rootDir/extappdata"
    val dataDir: String = "${this.rootDir}/data"
    val filesDir: String = "${this.rootDir}/files"
    val cacheDir: String = "${this.rootDir}/cache"
    val codeCacheDir: String = "${this.rootDir}/code_cache"
    val noBackupFilesDir: String = "${this.rootDir}/no_backup"
    val databasesDir: String = "${this.rootDir}/databases"
    val prefsDir: String = "${this.rootDir}/shared_prefs"
    val externalFilesDirs: MutableList<String> = mutableListOf("$externalStorageDir/files")
    val obbDirs: MutableList<String> = mutableListOf("$externalStorageDir/obb")
    val externalCacheDirs: MutableList<String> = mutableListOf("$externalStorageDir/cache")
    val externalMediaDirs: MutableList<String> = mutableListOf("$externalStorageDir/media")
    val downloadCacheDir: String = "$externalStorageDir/downloadCache"
    val packageDir: String = "$rootDir/android-compat/packages"
}

class ApplicationInfoConfigModule : ConfigModule() {
    val packageName: String = "eu.kanade.tachiyomi"
    val debug: Boolean = false
}

/** `android.os.SystemProperties` values. The reference config defines none. */
class SystemConfigModule(
    private val properties: Map<String, String> = emptyMap(),
) : ConfigModule() {
    val isDebuggable: Boolean = false

    fun getStringProperty(property: String): String = properties[property] ?: throw NoSuchElementException(property)

    fun getIntProperty(property: String): Int = getStringProperty(property).toInt()

    fun getLongProperty(property: String): Long = getStringProperty(property).toLong()

    fun getBooleanProperty(property: String): Boolean = getStringProperty(property).toBoolean()

    fun hasProperty(property: String): Boolean = property in properties
}
