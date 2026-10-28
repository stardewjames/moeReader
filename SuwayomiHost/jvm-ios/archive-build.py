#!/usr/bin/env python3
"""Archive the compiled tree package.sh needs; extract it at jvm-ios/.

The archive holds the outputs of fetch-openjdk.sh, build-openjdk-macos.sh and
build-openjdk-ios.sh. Packaging inputs (package.sh, jvm-options) are not in it,
so a host jar or VM-option change reuses these binaries.
"""

import sys
import tarfile
from pathlib import Path


def archive_build(work: Path, output: Path) -> None:
    ios = "mobile/build/ios-aarch64-zero-release"
    inputs = [
        "libffi/device",
        "mobile/build/macos-aarch64/images/jdk",
        f"{ios}/images/static-libs",
        f"{ios}/jdk/modules",
    ]
    # package.sh reads each static library's external linker flags from the
    # native build tree. Keep those pairs, not the intermediate object files.
    for flags in sorted((work / ios / "support/native").rglob("*.a.lib-flags.txt")):
        library = flags.with_name(flags.name.removesuffix(".lib-flags.txt"))
        if library.is_file():
            inputs.append(str(library.relative_to(work)))
            inputs.append(str(flags.relative_to(work)))

    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w:gz") as archive:
        for path in inputs:
            source = work / path
            if not source.exists():
                raise SystemExit(f"archive-build: missing compiled input {source}")
            archive.add(source, arcname=f"work/{path}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    archive_build(here / "work", Path(sys.argv[1]))
