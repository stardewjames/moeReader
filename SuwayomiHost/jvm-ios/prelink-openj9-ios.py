#!/usr/bin/env python3
"""Turns the OpenJ9 VM's shared libraries (an iOS build) into one static archive for the app.

OpenJ9 is a set of shared libraries (libjvm, libj9vm29, libj9gc29, ...) that load each other by
name and look up entry points by name (J9VMDllMain in each, JVM_OnLoad, ...). An iOS app cannot
load dylibs of its own outside frameworks, so jvm-ios links them statically:

1. Each library is prelinked (`ld -r`) from exactly the objects and static archives its dylib was
   linked from (CMake's link.txt). Only the library's intended exports (CMake's EXPORTED_SYMBOLS,
   written to <target>.exports by the OMR patch) stay global, so the private copies of utility
   code that every library links (j9util, omrutil, ...) cannot clash, as with real dylibs.
2. Exports that more than one library defines (J9VMDllMain, JVM_OnLoad, ...) are renamed to
   <symbol>_<library> (`ld -alias`); for JNI libraries that is the JNI_OnLoad_<library> name a
   statically linked JNI library must have.
3. A generated table maps (library, exported name) to the (renamed) symbol's address. A constructor
   registers it with the port library (omrsl_register_static_libraries, OMR patch), so "opening"
   e.g. j9gc29 and looking up J9VMDllMain in it finds J9VMDllMain_j9gc29.

4. The JDK's native libraries (built with STATIC_LIBS=true: JNI_OnLoad_<library>) are prelinked
   the same way, one object per library (`ld -r -force_load`), which makes their hidden helpers
   local (OpenJ9's JDK defines e.g. getTraceInterfaceFromVM in several of them). Where OpenJ9 and a
   JDK library define the same JNI function (jclse overrides some of libjava's), OpenJ9's copy is
   renamed and reached through the table, as each dylib kept its own before. The JDK libraries
   are in the table as well, for the ones the VM loads itself (libjimage).

Usage: prelink-openj9-ios.py iphoneos|iphonesimulator BUILD_DIR OUT_DIR
  BUILD_DIR: work/openj9-jdk21/build/<conf> (the VM is in vm/runtime)
  OUT_DIR:   receives libopenj9.a and prelink-report.txt
"""
import os
import re
import shlex
import subprocess
import sys
import tempfile

# The VM components the app links (CMake target names). Not linked: the JIT (j9jit, not built),
# the shared classes cache (j9shr; -Xshareclasses:none), the -Xcheck libraries and test libraries.
COMPONENTS = [
    "jvm",  # runtime/j9vm: JNI_CreateJavaVM and the JVM_* interface of the class library
    "j9vm",
    "j9thr",
    "j9prt",
    "omrsig",
    "j9hookable",
    "j9gc",
    "jclse",
    "j9zlib",
    "j9vrb",
    "j9dmp",
    "j9trc",
    "j9jvmti",
    "management_ext",  # OpenJ9's jdk.management natives (a JNI library)
]

# The JDK's native libraries the host needs: (module, library, helper archives linked into it).
JDK_LIBS = [
    ("java.base", "java", ["fdlibm"]),
    ("java.base", "zip", []),
    ("java.base", "jimage", []),
    ("java.base", "net", []),
    ("java.base", "nio", []),
    ("java.base", "syslookup", []),
    ("java.management", "management", []),
    ("java.prefs", "prefs", []),
    ("jdk.net", "extnet", []),
]

# System libraries and frameworks the prelinked code needs: zlib (libzip), libc++ (OpenJ9 is C++),
# iconv (OMR's string conversion), CoreFoundation/Foundation (libjava, libprefs), CFNetwork (system
# proxy selector in libnet) and MobileCoreServices (UTType file type detection in libnio).
SYSTEM_LIBS = ["-lz", "-lc++", "-liconv", "-framework", "CoreFoundation", "-framework", "Foundation",
               "-framework", "CFNetwork", "-framework", "MobileCoreServices"]

# omrsig exports libc's signal functions so that, as a dylib, it interposes on them for signal
# chaining. Linked into an app they would replace libc's for all of the executable's code, so they
# stay private (the VM itself uses omrsig_primary_signal/omrsig_primary_sigaction).
PRIVATE = {
    "omrsig": {"signal", "sigaction", "sigset", "sigignore", "bsd_signal", "sysv_signal", "__sysv_signal", "ssignal"},
}

# Library entry points that are always renamed to <symbol>_<library>, even when only one library
# exports them: generic names must not be global in the app, and a statically linked JNI library's
# JNI_OnLoad must be JNI_OnLoad_<library>.
ENTRY_POINTS = {"J9VMDllMain", "JVM_OnLoad", "JVM_OnUnload", "JNI_OnLoad", "JNI_OnUnload",
                "JCL_OnLoad", "Agent_OnLoad", "Agent_OnUnload", "Agent_OnAttach"}

IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def run(cmd, **kwargs):
    result = subprocess.run(cmd, text=True, capture_output=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"prelink: {' '.join(cmd)[:400]}\n{result.stderr[-4000:]}")
    return result.stdout


def find_link_txt(runtime, target):
    for root, dirs, files in os.walk(runtime):
        if os.path.basename(root) == f"{target}.dir" and "link.txt" in files:
            return os.path.join(root, "link.txt")
    raise SystemExit(f"prelink: no CMake link command for target {target} under {runtime}")


def parse_link(link_txt):
    """Objects, static archives and the dylib name of a CMake shared-library link command."""
    target_dir = os.path.dirname(os.path.dirname(os.path.dirname(link_txt)))  # .../<dir>/CMakeFiles/<t>.dir
    tokens = shlex.split(open(link_txt).read())
    inputs, output = [], None
    for i, token in enumerate(tokens):
        if token == "-o":
            output = tokens[i + 1]
        elif token.endswith(".o") or token.endswith(".a"):
            path = os.path.normpath(os.path.join(target_dir, token))
            if path not in inputs:
                inputs.append(path)
    if output is None:
        raise SystemExit(f"prelink: no -o in {link_txt}")
    name = os.path.basename(output)
    name = re.sub(r"^lib", "", re.sub(r"\.dylib$", "", name))
    return target_dir, inputs, name


def read_exports(path):
    if not os.path.exists(path):
        return []
    names = []
    for line in open(path):
        line = line.strip()
        if line.startswith("_") and len(line) > 1:
            names.append(line[1:])
    return names


def defined_globals(obj):
    out = run(["nm", "-gUj", obj])
    return {line[1:] for line in out.split() if line.startswith("_")}


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    platform, build_dir, out_dir = sys.argv[1:]
    runtime = os.path.join(build_dir, "vm", "runtime")
    os.makedirs(out_dir, exist_ok=True)
    sdk_version = run(["xcrun", "--sdk", platform, "--show-sdk-version"]).strip()
    min_version = os.environ.get("IOS_MIN", "26.0")
    ld_platform = "ios" if platform == "iphoneos" else "ios-simulator"
    ld = ["xcrun", "--sdk", platform, "ld", "-r", "-arch", "arm64", "-platform_version", ld_platform, min_version, sdk_version]

    work = tempfile.mkdtemp(prefix="prelink-", dir=out_dir)
    objects, table, report = [], [], []

    # The JDK's static JNI libraries, one object each.
    native = os.path.join(build_dir, "support", "native")
    jdk_globals = {}
    for module, name, helpers in JDK_LIBS:
        archive = os.path.join(native, module, f"lib{name}", "static", f"lib{name}.a")
        extra = [os.path.join(native, module, f"lib{h}", "static", f"lib{h}.a") for h in helpers]
        obj = os.path.join(out_dir, f"jdk-{name}.o")
        run(ld + ["-o", obj, "-force_load", archive] + extra)
        for symbol in sorted(defined_globals(obj)):
            if symbol in jdk_globals:
                raise SystemExit(f"prelink: {symbol} is defined by libraries {jdk_globals[symbol]} and {name}")
            jdk_globals[symbol] = name
            # The VM loads some JDK libraries itself (libjimage, to read lib/modules): they are in
            # the table under their own names too.
            table.append((name, symbol, symbol))
        objects.append(obj)
        report.append(f"jdk {name}: {len(defined_globals(obj))} globals")

    libs = {}  # target -> dict(name, inputs, exports)
    for target in COMPONENTS:
        target_dir, inputs, name = parse_link(find_link_txt(runtime, target))
        whole = os.path.join(work, f"{name}-all.o")
        run(ld + ["-o", whole] + inputs)
        defined = defined_globals(whole)
        wanted = [s for s in read_exports(os.path.join(target_dir, f"{target}.exports")) if s not in PRIVATE.get(target, set())]
        missing = [s for s in wanted if s not in defined]
        exports = [s for s in wanted if s in defined]
        libs[target] = {"name": name, "inputs": inputs, "exports": exports, "missing": missing}

    # Names exported by more than one library get a per-library name.
    owners = {}
    for target, lib in libs.items():
        for symbol in lib["exports"]:
            owners.setdefault(symbol, []).append(target)
    clashing = {s for s, t in owners.items() if len(t) > 1} | (set(owners) & ENTRY_POINTS) | (set(owners) & set(jdk_globals))
    for target, lib in libs.items():
        name = lib["name"]
        exported, aliases = [], []
        for symbol in lib["exports"]:
            linked = f"{symbol}_{name}" if symbol in clashing else symbol
            if linked != symbol:
                aliases += ["-alias", f"_{symbol}", f"_{linked}"]
            exported.append(linked)
            table.append((name, symbol, linked))
        exp = os.path.join(work, f"{name}.exp")
        with open(exp, "w") as f:
            f.write("".join(f"_{s}\n" for s in exported))
        obj = os.path.join(out_dir, f"openj9-{name}.o")
        run(ld + ["-o", obj] + lib["inputs"] + ["-exported_symbols_list", exp] + aliases)
        objects.append(obj)
        report.append(f"{name}: {len(lib['inputs'])} inputs, {len(exported)} exports"
                      + (f", renamed {sorted(s for s in lib['exports'] if s in clashing)}" if any(s in clashing for s in lib["exports"]) else "")
                      + (f", not defined (skipped) {lib['missing']}" if lib["missing"] else ""))

    # The static library table, registered with the port library before main().
    source = os.path.join(work, "openj9_static_libraries.c")
    with open(source, "w") as f:
        f.write("/* Generated by jvm-ios/prelink-openj9-ios.py: the OpenJ9 shared libraries linked into this executable. */\n")
        f.write("#include <stddef.h>\n\n")
        # Declared under private C names bound to the Mach-O symbols (asm labels), so no export
        # can clash with a declaration here.
        refs = {}
        for linked in sorted({t[2] for t in table if IDENTIFIER.match(t[2])}):
            refs[linked] = f"openj9_symbol_{len(refs)}"
            f.write(f'extern char {refs[linked]}[] __asm__("_{linked}");\n')
        f.write("\nstatic const struct { const char *library; const char *name; void *address; } symbols[] = {\n")
        for name, symbol, linked in table:
            if linked in refs:
                f.write(f'\t{{"{name}", "{symbol}", (void *){refs[linked]}}},\n')
        f.write("\t{NULL, NULL, NULL}\n};\n\n")
        f.write("extern void omrsl_register_static_libraries(const void *symbols);\n\n")
        f.write("__attribute__((constructor)) static void\nregister_openj9_static_libraries(void)\n{\n")
        f.write("\tomrsl_register_static_libraries(symbols);\n}\n")
    cc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "openj9-ios", platform, "bin", "cc")
    table_obj = os.path.join(out_dir, "openj9-static-libraries.o")
    run([cc, "-O2", "-c", source, "-o", table_obj])
    objects.append(table_obj)

    archive = os.path.join(out_dir, "libopenj9.a")
    if os.path.exists(archive):
        os.remove(archive)
    run(["xcrun", "--sdk", platform, "libtool", "-static", "-o", archive] + objects)
    # Everything else the app must link (system libraries the VM and the JDK libraries use).
    with open(os.path.join(out_dir, "link-flags.txt"), "w") as f:
        f.write(" ".join(["-force_load", archive] + SYSTEM_LIBS) + "\n")
    with open(os.path.join(out_dir, "prelink-report.txt"), "w") as f:
        f.write("\n".join(report) + f"\nrenamed: {sorted(clashing)}\ntable entries: {len(table)}\n")
    print("\n".join(report))
    print(f"renamed: {sorted(clashing)}")
    print(f"{archive}: {os.path.getsize(archive) // 1024} KB")


if __name__ == "__main__":
    main()
