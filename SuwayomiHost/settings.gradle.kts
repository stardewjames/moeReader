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
        // The stub jar is published on a moving branch; each upstream commit
        // drops the classes that its own AndroidCompat started implementing.
        // Pin the commit that matches the vendored AndroidCompat (the next
        // one removed android.net.Network*, which this tree still needs).
        maven("https://github.com/Suwayomi/Suwayomi-Server/raw/3983289d9481a8ba99c0b16350b27f41364906a2/")
        maven("https://jitpack.io")
    }
}

include(":host")
