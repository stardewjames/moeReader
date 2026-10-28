#!/usr/bin/env bash
# Runs the Suwayomi backend's Swift unit tests (MoeReaderTests/SuwayomiCompatTests.swift)
# and the backend-switching tests (MihonRuntimeSelectionTests.swift) on Linux, in
# Swift 6 mode like the app. No JVM is started.
# Env: HARNESS_PKG (default /tmp/suwayomi-swift-tests)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PKG=${HARNESS_PKG:-/tmp/suwayomi-swift-tests}
rm -rf "$PKG/Sources" "$PKG/Tests"
mkdir -p "$PKG/Sources/MoeReader" "$PKG/Sources/SuwayomiJNI" "$PKG/Tests/MoeReaderTests"
cp -R "$REPO/MoeReader/SuwayomiCompat/JNI/." "$PKG/Sources/SuwayomiJNI/"
cp "$REPO"/MoeReader/SuwayomiCompat/*.swift "$PKG/Sources/MoeReader/"
for f in MihonBinaryXML MihonCrypto MihonErrors MihonGzip MihonInflate MihonModels MihonRuntimeBackend MihonSourceRuntime MihonZIPArchive; do
  cp "$REPO/MoeReader/MihonExtensions/$f.swift" "$PKG/Sources/MoeReader/"
done
cp "$REPO/MoeReaderTests/SuwayomiCompatTests.swift" "$REPO/MoeReaderTests/MihonRuntimeSelectionTests.swift" \
   "$REPO/MoeReaderTests/TestSupport.swift" "$PKG/Tests/MoeReaderTests/"
cp -R "$REPO/MoeReaderTests/Fixtures" "$PKG/Tests/MoeReaderTests/"
cat > "$PKG/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SuwayomiSwiftTests",
    targets: [
        .target(name: "SuwayomiJNI", path: "Sources/SuwayomiJNI", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("dl")]),
        .target(name: "MoeReader", dependencies: ["SuwayomiJNI"], path: "Sources/MoeReader",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MoeReaderTests", dependencies: ["MoeReader"], path: "Tests/MoeReaderTests",
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
EOF
cd "$PKG"
swift build --build-tests 2>&1 | grep -E "error|Compiling|Build" | tail -30
swift test 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]" | tail -40
