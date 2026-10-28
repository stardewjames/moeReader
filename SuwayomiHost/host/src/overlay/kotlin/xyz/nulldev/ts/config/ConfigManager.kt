package xyz.nulldev.ts.config

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: replaces Suwayomi's AndroidCompat/Config project
 * (ConfigManager.kt, ConfigModule.kt, ApplicationRootDir.kt,
 * ConfigManagerModule.kt). Upstream parses HOCON files with typesafe-config and
 * binds them through config4k and kotlin-reflect; on an interpreter-only JVM
 * that costs seconds at every start for a handful of fixed directory values.
 * The host supplies those values directly (moe.reader.suwayomi.HostConfig), so
 * this keeps only the API AndroidCompat calls: module lookup and registration.
 */

import org.koin.core.module.Module
import org.koin.dsl.module

/** Root of the emulated Android app's files. Set once by the host at boot. */
val ApplicationRootDir: String
    get() = System.getProperty(ROOT_DIR_PROPERTY) ?: error("$ROOT_DIR_PROPERTY is not set; the host has not booted")

const val ROOT_DIR_PROPERTY = "moereader.suwayomi.rootDir"

/** Marker base class of the AndroidCompat config modules. */
abstract class ConfigModule

open class ConfigManager {
    private val modules = HashMap<Class<out ConfigModule>, ConfigModule>()

    val loadedModules: Map<Class<out ConfigModule>, ConfigModule>
        get() = modules

    inline fun <reified T : ConfigModule> module(): T = module(T::class.java)

    @Suppress("UNCHECKED_CAST")
    fun <T : ConfigModule> module(type: Class<T>): T =
        synchronized(this) { modules[type] } as? T ?: error("config module ${type.name} is not registered")

    fun registerModule(module: ConfigModule) {
        synchronized(this) { modules[module.javaClass] = module }
    }

    fun registerModules(vararg modules: ConfigModule) {
        modules.forEach(::registerModule)
    }
}

object GlobalConfigManager : ConfigManager()

fun configManagerModule(): Module =
    module {
        single<ConfigManager> { GlobalConfigManager }
    }
