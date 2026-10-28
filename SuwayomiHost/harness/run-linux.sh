#!/usr/bin/env bash
# Builds the SuwayomiCompat Swift sources, the JNI shim and a harness into a
# SwiftPM package and runs one extension through the whole stack on a desktop
# HotSpot. Needs a Linux Swift toolchain, a JDK 21 (libjvm) and the desktop
# runtime (`./gradlew :host:desktopRuntime` in SuwayomiHost).
#
# Usage: run-linux.sh <extension.apk> [source-index] [search-query]
# Env:   HARNESS_PKG (default /tmp/suwayomi-harness), JAVA_HOME
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PKG=${HARNESS_PKG:-/tmp/suwayomi-harness}
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}
RUNTIME="$REPO/SuwayomiHost/host/build/runtime/desktop"
test -f "$RUNTIME/host/suwayomi-host.jar" || { echo "missing $RUNTIME; run ./gradlew :host:desktopRuntime" >&2; exit 1; }

rm -rf "$PKG/Sources"
mkdir -p "$PKG/Sources/Harness" "$PKG/Sources/SuwayomiJNI"
cp -R "$REPO/MoeReader/SuwayomiCompat/JNI/." "$PKG/Sources/SuwayomiJNI/"
cp "$REPO"/MoeReader/SuwayomiCompat/*.swift "$PKG/Sources/Harness/"
for f in MihonBinaryXML MihonCrypto MihonErrors MihonGzip MihonInflate MihonModels MihonRuntimeBackend MihonSourceRuntime MihonZIPArchive; do
  cp "$REPO/MoeReader/MihonExtensions/$f.swift" "$PKG/Sources/Harness/"
done
cp "$HERE/main.swift" "$PKG/Sources/Harness/Harness.swift"
cat > "$PKG/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SuwayomiHarness",
    targets: [
        .target(name: "SuwayomiJNI", path: "Sources/SuwayomiJNI", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "Harness", dependencies: ["SuwayomiJNI"], path: "Sources/Harness",
                          // The app builds with Swift 6 and complete concurrency checking.
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
EOF
cd "$PKG"
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build" | tail -40
export SUWAYOMI_RUNTIME_DIR="$RUNTIME"
export SUWAYOMI_LIBJVM="$JAVA_HOME/lib/server/libjvm.so"
exec ./.build/release/Harness "$@"
