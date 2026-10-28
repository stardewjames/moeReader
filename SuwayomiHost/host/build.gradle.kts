import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

// The host compiles a filtered subset of the vendored Suwayomi-Server tree
// (AndroidCompat plus the Tachiyomi source API) next to MoeReader's bridge.
// Vendor files that must behave differently on a phone are excluded here and
// re-implemented under the same fully-qualified name in src/overlay; the
// vendor tree itself is never edited. The include/exclude lists started from
// the Oneechan runtime's source-api build (MPL-2.0); MoeReader's own overlays
// and exclusions are listed here.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.shadowjar)
}

private val vendor = rootProject.file("vendor/suwayomi")
private val targetJava = libs.versions.jvmTarget.get()

private val androidCompatExcludes = listOf(
    // Desktop Chromium (KCEF) WebView and the androidx.webkit glue around it.
    "xyz/nulldev/androidcompat/webkit/KcefWebViewProvider.kt",
    "xyz/nulldev/androidcompat/webkit/KcefHelper.kt",
    "xyz/nulldev/androidcompat/webkit/CefHelper.kt",
    "xyz/nulldev/androidcompat/webkit/KcefWebSettings.kt",
    "org/chromium/**",
    // HOCON config + config4k reflection: replaced by plain values (overlay).
    "xyz/nulldev/androidcompat/config/**",
    // Overlaid: see src/overlay.
    "xyz/nulldev/androidcompat/AndroidCompatInitializer.kt",
    "xyz/nulldev/androidcompat/io/sharedprefs/JavaSharedPreferences.kt",
    "app/cash/quickjs/QuickJs.java",
)

private val serverIncludes = listOf(
    "eu/kanade/tachiyomi/App.kt",
    "eu/kanade/tachiyomi/AppModule.kt",
    "eu/kanade/tachiyomi/network/**",
    "eu/kanade/tachiyomi/source/**",
    "eu/kanade/tachiyomi/util/**",
    "suwayomi/tachidesk/manga/impl/util/lang/RxCoroutineBridge.kt",
    "suwayomi/tachidesk/manga/impl/util/lang/JsonObject.kt",
    "suwayomi/tachidesk/manga/impl/util/BytecodeEditor.kt",
    "suwayomi/tachidesk/manga/impl/util/ChildFirstURLClassLoader.kt",
)

private val serverExcludes = listOf(
    // Server features the host does not ship: the local source and EPUB reading
    // live in the app.
    "eu/kanade/tachiyomi/source/local/**",
    "eu/kanade/tachiyomi/util/storage/EpubFile.kt",
    // Overlaid: see src/overlay.
    "eu/kanade/tachiyomi/AppInfo.kt",
    "eu/kanade/tachiyomi/network/NetworkHelper.kt",
    "eu/kanade/tachiyomi/network/PersistentCookieStore.kt",
    "eu/kanade/tachiyomi/network/interceptor/CloudflareInterceptor.kt",
)

// Exclude patterns on a source set apply to every root, overlays included, so
// the filtered vendor trees are materialised under build/ instead.
val syncAndroidCompat = tasks.register<Sync>("syncAndroidCompat") {
    from(vendor.resolve("AndroidCompat/src/main/java")) { exclude(androidCompatExcludes) }
    into(layout.buildDirectory.dir("vendor/android-compat"))
}

val syncSourceApi = tasks.register<Sync>("syncSourceApi") {
    from(vendor.resolve("server/src/main/kotlin")) {
        include(serverIncludes)
        exclude(serverExcludes)
    }
    into(layout.buildDirectory.dir("vendor/source-api"))
}

sourceSets.main {
    java.srcDirs(syncAndroidCompat, "src/overlay/java")
    kotlin.srcDirs(syncAndroidCompat, syncSourceApi, "src/overlay/java", "src/overlay/kotlin", "src/main/kotlin")
}

// Android API stubs. The stub jar also carries classes AndroidCompat and the
// overlays implement; on the host's flat class path a stub could win and throw
// "Stub!", so every implemented class (and its nested classes / Kotlin facade)
// is stripped from it, as Suwayomi's getAndroid.sh does.
val androidStubs: Configuration by configurations.creating { isTransitive = false }

private val implementingRoots = files(syncAndroidCompat, syncSourceApi, "src/overlay/java", "src/overlay/kotlin")

val filteredAndroidStubs = tasks.register<Jar>("filteredAndroidStubs") {
    archiveFileName = "android-stubs-filtered.jar"
    destinationDirectory = layout.buildDirectory.dir("stubs")
    inputs.files(implementingRoots)
    val stubs = androidStubs
    dependsOn(stubs)
    val implemented = provider {
        implementingRoots.files.filter { it.isDirectory }.flatMapTo(HashSet()) { root ->
            fileTree(root).matching { include("**/*.java", "**/*.kt") }.files.map {
                it.relativeTo(root).invariantSeparatorsPath.substringBeforeLast('.')
            }
        }
    }
    from({ zipTree(stubs.singleFile) }) {
        // The framework's compiled resources (resources.arsc, res/) are ~45 MB
        // no extension reads through AndroidCompat; only classes are kept.
        include("**/*.class")
        exclude { element ->
            val path = element.relativePath.pathString
            if (!path.endsWith(".class")) return@exclude false
            val outer = path.removeSuffix(".class").substringBefore('$')
            val names = implemented.get()
            outer in names || (outer.endsWith("Kt") && outer.removeSuffix("Kt") in names)
        }
    }
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

dependencies {
    androidStubs(libs.android.stubs)
    implementation(files(filteredAndroidStubs))

    // Libraries extensions are compiled against (versions from the vendored catalog).
    implementation(libs.kotlin.stdlib.jdk8)
    implementation(libs.kotlin.reflect)
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.jdk8)
    implementation(libs.serialization.json)
    implementation(libs.serialization.json.okio)
    implementation(libs.serialization.protobuf)
    implementation(libs.serialization.xml.core)
    implementation(libs.serialization.xml)
    // okhttp with the modules Suwayomi ships (logging, DoH, brotli, zstd).
    implementation(libs.bundles.okhttp)
    implementation(libs.okio)
    implementation(libs.jsoup)
    implementation(libs.rxjava)
    implementation(libs.injekt)
    implementation(libs.koin.core)
    implementation(libs.bouncycastle)
    // android.icu SimpleDateFormat/Calendar replacements extensions are rewritten to.
    implementation(libs.icu4j)
    // Natural ordering used by the Tachiyomi string helpers.
    implementation(libs.sort)
    implementation(libs.jackson.annotations)
    implementation(libs.slf4japi)
    implementation(libs.kotlinlogging)
    // Vendor code logs through SLF4J; the host keeps none of it (no logger
    // formatting work on the phone) and says so instead of warning at boot.
    runtimeOnly("org.slf4j:slf4j-nop:${libs.slf4japi.get().version}")

    // APK -> JAR conversion and the bytecode fix-ups Suwayomi applies.
    implementation(libs.dex2jar.translator)
    implementation(libs.asm)
    // AndroidCompat's package manager reads APK metadata with these.
    implementation(libs.apk.parser)
    implementation(libs.axml)

    compileOnly(libs.xmlpull)
    compileOnly(libs.apksig)
    compileOnly(libs.android.annotations)

    testImplementation(libs.kotlin.test.junit5)
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

java {
    sourceCompatibility = JavaVersion.toVersion(targetJava)
    targetCompatibility = JavaVersion.toVersion(targetJava)
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    // Vendored Android sources are noisy; warnings there are not ours to fix.
    options.compilerArgs.addAll(listOf("-Xlint:none", "-nowarn"))
}

tasks.withType<KotlinJvmCompile>().configureEach {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget(targetJava)
        freeCompilerArgs.add("-Xcontext-parameters")
        suppressWarnings = true
    }
}

tasks.test {
    useJUnitPlatform()
    // dex2jar output is not verifiable bytecode; the embedded JVMs run with
    // verification off too.
    jvmArgs("-XX:+UnlockDiagnosticVMOptions", "-XX:-BytecodeVerificationRemote")
    systemProperty("java.awt.headless", "true")
    // Opt-in live test against a real extension APK (never committed).
    System.getenv("SUWAYOMI_TEST_APK")?.let { environment("SUWAYOMI_TEST_APK", it) }
    // Extra VM flags, e.g. SUWAYOMI_TEST_JVM_ARGS=-Xint to time the
    // interpreter-only mode the phone runs in.
    System.getenv("SUWAYOMI_TEST_JVM_ARGS")?.let { jvmArgs(it.split(' ').filter(String::isNotBlank)) }
    testLogging {
        events("failed", "skipped", "passed")
        showStandardStreams = System.getenv("SUWAYOMI_TEST_APK") != null
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// The jar the app bundles (SuwayomiHost/jvm-ios/package.sh copies it).
tasks.shadowJar {
    archiveBaseName = "suwayomi-host"
    archiveClassifier = ""
    archiveVersion = ""
    mergeServiceFiles()
    // The host's own classes come first, so its patched dex2jar NewTransformer
    // replaces the library copy.
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    // Desktop-only payloads a phone never loads: AndroidCompat's Noto fonts
    // (text layout has no AWT on iOS), native libraries packed in jars, and
    // signature files of repackaged dependencies.
    exclude("font/**", "native/**", "jni/**", "META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/versions/9/module-info.class")
}

// The runtime directory layout the app expects (SuwayomiRuntimeLayout), for a
// desktop HotSpot: point SUWAYOMI_RUNTIME_DIR at it and SUWAYOMI_LIBJVM at a
// libjvm. The iOS layout is written by jvm-ios/package.sh.
tasks.register<Sync>("desktopRuntime") {
    from(tasks.shadowJar) { into("host") }
    from(rootProject.file("jvm-options/hotspot.options")) { rename { "jvm.options" } }
    into(layout.buildDirectory.dir("runtime/desktop"))
}
