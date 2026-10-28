package moe.reader.suwayomi

import eu.kanade.tachiyomi.App
import eu.kanade.tachiyomi.createAppModule
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.koin.core.context.startKoin
import xyz.nulldev.androidcompat.AndroidCompat
import xyz.nulldev.androidcompat.AndroidCompatInitializer
import xyz.nulldev.androidcompat.androidCompatModule
import xyz.nulldev.androidcompat.config.ApplicationInfoConfigModule
import xyz.nulldev.androidcompat.config.FilesConfigModule
import xyz.nulldev.androidcompat.config.SystemConfigModule
import xyz.nulldev.ts.config.GlobalConfigManager
import xyz.nulldev.ts.config.ROOT_DIR_PROPERTY
import xyz.nulldev.ts.config.configManagerModule
import java.io.File
import java.security.Security

/** Directories and identity the app hands the host at boot. */
class HostConfig(
    /** Persistent, not backed up: converted jars, AndroidCompat app data, preferences. */
    val dataDir: File,
    /** Purgeable scratch space extensions may use. */
    val cacheDir: File,
    /** The user agent sources get from `NetworkHelper.defaultUserAgentProvider()`. */
    val userAgent: String,
)

/**
 * Process-wide host state. Booted once per JVM (the JVM itself cannot be
 * restarted inside an app process); everything per extension lives in
 * [ExtensionRegistry] and can be dropped and rebuilt.
 */
object Host {
    @Volatile private var bootedConfig: HostConfig? = null

    @Volatile private var bootedServices: HostServices? = null

    val config: HostConfig get() = bootedConfig ?: error("the Suwayomi host has not booted")

    val services: HostServices get() = bootedServices ?: error("the Suwayomi host has not booted")

    val isBooted: Boolean get() = bootedConfig != null

    /**
     * Mirrors the Android half of Suwayomi's `applicationSetup`: config modules,
     * Koin with the Android compat and Tachiyomi app modules, then the emulated
     * `Application`. Server parts (database, web server, updater, downloader,
     * trackers, tray, KCEF) are not part of the host.
     */
    @Synchronized
    fun boot(
        config: HostConfig,
        services: HostServices,
    ) {
        check(bootedConfig == null) { "the Suwayomi host is already booted" }
        bootedServices = services
        bootedConfig = config

        val root = File(config.dataDir, "android")
        root.mkdirs()
        config.cacheDir.mkdirs()
        System.setProperty(ROOT_DIR_PROPERTY, root.absolutePath)
        System.setProperty("http.agent", config.userAgent)

        GlobalConfigManager.registerModules(
            FilesConfigModule(root.absolutePath),
            ApplicationInfoConfigModule(),
            SystemConfigModule(),
        )

        val app = App()
        startKoin {
            modules(
                createAppModule(app),
                androidCompatModule(),
                configManagerModule(),
            )
        }
        AndroidCompatInitializer().init()
        AndroidCompat().startApp(app)

        // Extensions ask for ciphers by Android names (AES/CBC/PKCS7Padding)
        // the JDK providers do not register.
        Security.addProvider(BouncyCastleProvider())
    }
}
