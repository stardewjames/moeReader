// The cut-down Suwayomi extension host embedded by MoeReader's SuwayomiCompat
// backend. Suwayomi-Server is a pinned submodule (vendor/suwayomi); the host
// compiles a subset of its AndroidCompat and Tachiyomi source API directly from
// that tree. See README.md.
rootProject.name = "suwayomi-host"

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    versionCatalogs {
        // Extensions are compiled against these library versions, so they are
        // taken verbatim from the vendored Suwayomi-Server.
        create("libs") { from(files("vendor/suwayomi/gradle/libs.versions.toml")) }
    }
    repositories {
        mavenCentral()
        google()
        maven("https://github.com/Suwayomi/Suwayomi-Server/raw/android-jar/")
        maven("https://jitpack.io")
    }
}

include(":host")
