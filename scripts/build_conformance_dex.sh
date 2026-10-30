#!/usr/bin/env bash
# Regenerates the Dalvik differential conformance fixtures:
#   MoeReaderTests/Fixtures/conformance.expected  (results on HotSpot, the reference)
#   MoeReaderTests/Fixtures/conformance.dex       (the same programs for the engine)
# from the Java sources in MoeReaderTests/Fixtures/conformance/src.
#
# Needs JDK 21 (javac/java; the IndyGen class is written with the JDK-internal
# jdk.internal.classfile API) and Android build-tools (d8, dexdump) plus an
# android.jar. Override locations with JAVA_HOME, ANDROID_BUILD_TOOLS and
# ANDROID_JAR. Run from anywhere (WSL/Linux/macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/MoeReaderTests/Fixtures"
SRC="$FIXTURES/conformance/src"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$HOME/android-sdk/build-tools/36.0.0}"
ANDROID_JAR="${ANDROID_JAR:-$HOME/android-sdk/platforms/android-36/android.jar}"
if [ -n "${JAVA_HOME:-}" ]; then
  JAVA="$JAVA_HOME/bin/java"
  JAVAC="$JAVA_HOME/bin/javac"
else
  JAVA=java
  JAVAC=javac
fi
D8="$BUILD_TOOLS/d8"
DEXDUMP="$BUILD_TOOLS/dexdump"

for tool in "$D8" "$DEXDUMP" "$ANDROID_JAR"; do
  [ -e "$tool" ] || { echo "missing: $tool" >&2; exit 1; }
done
"$JAVA" -version 2>&1 | grep -q 'version "21' || { echo "JDK 21 required (jdk.internal.classfile)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tools" "$WORK/classes" "$WORK/dex"

CLASSFILE_EXPORTS=(--add-exports java.base/jdk.internal.classfile=ALL-UNNAMED)

# 1. The class-file generator (JVM-only) writes conformance/IndyGen.class.
"$JAVAC" -nowarn -d "$WORK/tools" "${CLASSFILE_EXPORTS[@]}" "$SRC/conformance/IndyGenerator.java"
"$JAVA" "${CLASSFILE_EXPORTS[@]}" -cp "$WORK/tools" conformance.IndyGenerator "$WORK/classes"

# 2. The case classes, compiled against the generated class.
mapfile -t SOURCES < <(find "$SRC/conformance" -name '*.java' ! -name 'IndyGenerator.java' | LC_ALL=C sort)
"$JAVAC" -nowarn --release 17 -encoding UTF-8 -cp "$WORK/classes" -d "$WORK/classes" "${SOURCES[@]}"

# 3. Reference results from HotSpot. -Xint keeps the JIT out of the picture;
#    the locale/timezone are pinned so nothing environmental leaks in.
LC_ALL=C TZ=UTC "$JAVA" -Xint -Duser.language=en -Duser.country=US -Dfile.encoding=UTF-8 \
  -cp "$WORK/classes" conformance.Runner "$WORK/conformance.expected"

# 4. One dex, release mode, min-api 28 so d8 keeps invoke-polymorphic (26+),
#    invoke-custom (26+), const-method-handle and const-method-type (28+).
#    The JVM-only Runner is left out.
mapfile -t CLASSES < <(cd "$WORK/classes" && find conformance -name '*.class' ! -name 'Runner.class' ! -name 'Runner$*.class' | LC_ALL=C sort)
(cd "$WORK/classes" && "$D8" --release --min-api 28 --lib "$ANDROID_JAR" --output "$WORK/dex" "${CLASSES[@]}")
[ "$(find "$WORK/dex" -name '*.dex' | wc -l)" -eq 1 ] || { echo "d8 produced more than one dex" >&2; exit 1; }

# 5. The dex must contain the instructions and encodings this suite exists for.
"$DEXDUMP" -d "$WORK/dex/classes.dex" > "$WORK/dump.txt"
for opcode in invoke-polymorphic invoke-custom const-method-handle const-method-type fill-array-data packed-switch sparse-switch filled-new-array; do
  grep -q " $opcode" "$WORK/dump.txt" || { echo "dex lacks $opcode" >&2; exit 1; }
done
# Encoded static values: dexdump prints "value" for each static field whose
# initial value lives in the class's encoded_array_item.
check_static_value() {
  local cls=$1 field=$2 type=$3
  awk -v cls="Class descriptor  : '$cls'" -v field="name          : '$field'" -v type="type          : '$type'" '
    $0 ~ /Class descriptor/ { inclass = (index($0, cls) > 0) }
    inclass && /Static fields/ { instatic = 1 }
    inclass && /Instance fields/ { instatic = 0 }
    inclass && instatic && index($0, field) { seen = 1; next }
    seen && index($0, type) { typed = 1; next }
    seen && typed && /value/ { found = 1; exit }
    seen && /#[0-9]+/ { seen = 0; typed = 0 }
    END { exit found ? 0 : 1 }
  ' "$WORK/dump.txt" || { echo "no encoded static value for $cls.$field ($type)" >&2; exit 1; }
}
check_static_value 'Lconformance/StaticValueCases$Values;' F F
check_static_value 'Lconformance/StaticValueCases$Values;' D D
check_static_value 'Lconformance/StaticValueCases$Values;' FNEG_ZERO F
check_static_value 'Lconformance/StaticValueCases$Values;' DNEG D
check_static_value 'Lconformance/StaticValueCases$Values;' L J
check_static_value 'Lconformance/StaticValueCases$Values;' B B


# 6. A real v041 container (experimental in d8) also exercises physical
# offsets and the extended header. Rebuild it rather than hand-writing bytes.
mkdir -p "$WORK/container-source" "$WORK/container-classes" "$WORK/container-dex"
cat > "$WORK/container-source/A.java" <<'JAVA'
public class A { public static int f() { return 1; } }
JAVA
cat > "$WORK/container-source/B.java" <<'JAVA'
public class B { public static int g() { return A.f() + 1; } }
JAVA
"$JAVAC" --release 17 -g:none -d "$WORK/container-classes" "$WORK/container-source/"*.java
"$JAVA" -Dcom.android.tools.r8.dexContainerExperiment=true -cp "$BUILD_TOOLS/lib/d8.jar" \
  com.android.tools.r8.D8 --release --min-api 36 --lib "$ANDROID_JAR" \
  --output "$WORK/container-dex" "$WORK/container-classes/"*.class
cp "$WORK/container-dex/classes.dex" "$FIXTURES/dex041.dex"
cp "$WORK/dex/classes.dex" "$FIXTURES/conformance.dex"
cp "$WORK/conformance.expected" "$FIXTURES/conformance.expected"
echo "wrote $(wc -l < "$FIXTURES/conformance.expected") cases; dex $(wc -c < "$FIXTURES/conformance.dex") bytes"
