#!/usr/bin/env python3
"""Static compatibility audit for the Mihon extension engine.

Two independent sources of truth:

1. Every class/method the engine registers in ``MihonCompat/Engine`` (parsed
   from the Swift registration calls).
2. Every external class/method referenced by an extension APK's DEX files.

The report lists host API references with no matching native implementation,
grouped by package, plus methods missing from classes that are registered.
Interface and superclass methods count as present when any concrete registered
implementation provides them, matching virtual dispatch on the receiver.

Usage:
    python3 scripts/analyze_compat.py [extension.apk ...]

With no APK argument the script only prints the registry inventory.
No third-party dependencies; safe to run on a plain Python 3 install.
"""

from __future__ import annotations

import re
import struct
import sys
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "MoeReader" / "MihonCompat" / "Engine"

# Packages an extension expects the *host* to provide. Anything referenced
# from these roots that the APK does not define itself is a compat obligation.
HOST_PREFIXES = (
    "Ljava/",
    "Ljavax/",
    "Lkotlin/",
    "Lkotlinx/",
    "Landroid/",
    "Landroidx/",
    "Lokhttp3/",
    "Lokio/",
    "Lorg/jsoup/",
    "Lorg/intellij/",
    "Leu/kanade/tachiyomi/",
    "Lcom/squareup/",
    "Lorg/slf4j/",
    "Lio/reactivex/",
    "Lrx/",
)


# ---------------------------------------------------------------------------
# DEX reader (types, protos, methods, class definitions)
# ---------------------------------------------------------------------------


class Dex:
    def __init__(self, data: bytes) -> None:
        self.data = data
        (self.string_ids_size, self.string_ids_off, self.type_ids_size,
         self.type_ids_off, self.proto_ids_size, self.proto_ids_off,
         _field_size, _field_off, self.method_ids_size, self.method_ids_off,
         self.class_defs_size, self.class_defs_off) = struct.unpack_from(
            "<12I", data, 0x38)

    def u32(self, off: int) -> int:
        return struct.unpack_from("<I", self.data, off)[0]

    def string(self, index: int) -> str:
        off = self.u32(self.string_ids_off + index * 4)
        _length, pos = self.uleb(off)
        end = self.data.index(b"\x00", pos)
        return self.data[pos:end].decode("utf-8", "replace")

    def type(self, index: int) -> str:
        return self.string(self.u32(self.type_ids_off + index * 4))

    def uleb(self, off: int) -> tuple[int, int]:
        value = shift = 0
        while True:
            byte = self.data[off]
            off += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value, off
            shift += 7

    def proto(self, index: int) -> tuple[list[str], str]:
        _short, return_idx, params_off = struct.unpack_from(
            "<III", self.data, self.proto_ids_off + index * 12)
        params: list[str] = []
        if params_off:
            size = self.u32(params_off)
            for i in range(size):
                # Type lists store u16 type indices, unlike most tables.
                index = struct.unpack_from(
                    "<H", self.data, params_off + 4 + i * 2)[0]
                params.append(self.type(index))
        return params, self.type(return_idx)

    def method(self, index: int) -> tuple[str, str, str]:
        _class_idx, proto_idx, name_idx = struct.unpack_from(
            "<HHI", self.data, self.method_ids_off + index * 8)
        params, ret = self.proto(proto_idx)
        name = self.string(name_idx)
        return name, "(" + "".join(params) + ")" + ret, ""

    def methods(self):
        for i in range(self.method_ids_size):
            class_idx = struct.unpack_from("<H", self.data, self.method_ids_off + i * 8)[0]
            _class_idx, proto_idx, name_idx = struct.unpack_from(
                "<HHI", self.data, self.method_ids_off + i * 8)
            params, ret = self.proto(proto_idx)
            yield (self.type(class_idx), self.string(name_idx),
                   "(" + "".join(params) + ")" + ret)

    def defined_classes(self) -> set[str]:
        result = set()
        for i in range(self.class_defs_size):
            type_idx = self.u32(self.class_defs_off + i * 32)
            result.add(self.type(type_idx))
        return result


def dex_files(apk_path: Path) -> list[bytes]:
    with zipfile.ZipFile(apk_path) as archive:
        return [archive.read(name) for name in archive.namelist()
                if re.fullmatch(r"classes\d*\.dex", name)]


def descriptor_name(descriptor: str) -> str:
    """Human-readable binary name for a type descriptor (arrays included)."""
    dims = 0
    while descriptor.startswith("["):
        dims += 1
        descriptor = descriptor[1:]
    if descriptor.startswith("L"):
        name = descriptor[1:-1].replace("/", ".")
    else:
        name = descriptor
    return name + "[]" * dims


# ---------------------------------------------------------------------------
# Native registry reader (Swift registration calls)
# ---------------------------------------------------------------------------

CLASS_RE = re.compile(r'NativeClass\("(L[^"]+;)"')
METHOD_RE = re.compile(
    r'\.(?:method|staticMethod|privateMethod|methodSignatureOnly)'
    r'\("([^"]+)",\s*"([^"]+)"')
# Concrete classes produced by generic helpers, e.g. collection shims built in
# a loop, declare their descriptor through this helper's argument.
FACTORY_RE = re.compile(r'\.(?:method|staticMethod)\(\s*([A-Za-z_][\w.]*)\s*,')


@dataclass
class Registry:
    classes: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    sources: dict[str, str] = field(default_factory=dict)
    parents: dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))

    def resolve(self, descriptor: str, seen: set[str] | None = None) -> set[str]:
        """Own and inherited methods, like JVM virtual dispatch."""
        seen = seen or set()
        if descriptor in seen:
            return set()
        seen.add(descriptor)
        methods = set(self.classes.get(descriptor, ()))
        for parent in self.parents.get(descriptor, ()):
            if parent:
                methods |= self.resolve(parent, seen)
        return methods

    def has_class(self, descriptor: str) -> bool:
        return descriptor in self.classes

    def has_method(self, descriptor: str, key: str) -> bool:
        if key in self.resolve(descriptor):
            return True
        # A method declared only by an interface is dispatched through the
        # receiver's concrete class. Treat it as present when any registered
        # implementation of that interface provides it.
        for cls in self.classes:
            if cls == descriptor or key not in self.classes[cls]:
                continue
            if descriptor in self.ancestors(cls):
                return True
        return False

    def ancestors(self, descriptor: str, seen: set[str] | None = None) -> set[str]:
        seen = seen or set()
        if descriptor in seen:
            return set()
        seen.add(descriptor)
        result: set[str] = set()
        for parent in self.parents.get(descriptor, ()):
            result.add(parent)
            result |= self.ancestors(parent, seen)
        return result


def parse_registry() -> Registry:
    registry = Registry()
    for path in sorted(ENGINE.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        starts = [m.start() for m in CLASS_RE.finditer(text)]
        # A class's methods are registered after its constructor and before
        # the next NativeClass constructor (registrations are sequential in
        # every provider).
        for position, start in enumerate(starts):
            match = CLASS_RE.match(text, start)
            assert match is not None
            descriptor = match.group(1)
            end = starts[position + 1] if position + 1 < len(starts) else len(text)
            segment = text[start:end]
            registry.classes.setdefault(descriptor, set())
            registry.sources.setdefault(descriptor, path.name)
            for m in METHOD_RE.finditer(segment):
                registry.classes[descriptor].add(m.group(1) + m.group(2))
    return registry


def dynamic_registration_sites() -> list[str]:
    """Classes built from a variable descriptor, invisible to the static pass."""
    sites: list[str] = []
    for path in sorted(ENGINE.glob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "NativeClass(descriptor" in line:
                sites.append(f"{path.name}:{number}")
    return sites


def package_of(descriptor: str) -> str:
    name = descriptor
    dims = 0
    while name.startswith("["):
        dims += 1
        name = name[1:]
    if not name.startswith("L"):
        return "primitive"
    parts = name[1:-1].split("/")
    return ".".join(parts[:2]) if len(parts) > 1 else ".".join(parts[:1])


def load_registry(path: Path) -> Registry:
    """Load the exact class/method map dumped by the engine."""
    import json
    data = json.loads(path.read_text(encoding="utf-8"))
    registry = Registry()
    for descriptor, info in data.items():
        registry.sources[descriptor] = "runtime"
        if isinstance(info, list):
            registry.classes[descriptor] = set(info)
            continue
        registry.classes[descriptor] = set(info.get("methods", []))
        parents = [info.get("super", "")] + list(info.get("interfaces", []))
        registry.parents[descriptor] = [parent for parent in parents if parent]
    return registry


def main(argv: list[str]) -> int:
    registry_path: Path | None = None
    if "--registry" in argv:
        index = argv.index("--registry")
        try:
            registry_path = Path(argv[index + 1])
        except IndexError:
            print("--registry requires a JSON path", file=sys.stderr)
            return 2
        argv = argv[:index] + argv[index + 2:]
    registry = load_registry(registry_path) if registry_path else parse_registry()
    print(f"registry ({'runtime' if registry_path else 'static'}): "
          f"{len(registry.classes)} classes, "
          f"{sum(len(v) for v in registry.classes.values())} methods")
    if not argv:
        return 0

    for argument in argv:
        apk = Path(argument)
        for index, blob in enumerate(dex_files(apk)):
            dex = Dex(blob)
            defined = dex.defined_classes()
            missing_classes: dict[str, set[str]] = defaultdict(set)
            missing_methods: dict[str, set[str]] = defaultdict(set)
            used_classes: Counter[str] = Counter()
            for owner, name, signature in dex.methods():
                if owner in defined:
                    continue
                if not owner.startswith(HOST_PREFIXES):
                    continue
                used_classes[owner] += 1
                if not registry.has_class(owner):
                    missing_classes[owner].add(name + signature)
                elif not registry.has_method(owner, name + signature):
                    missing_methods[owner].add(name + signature)

            print(f"\n=== {apk.name} classes{index}.dex: {len(defined)} defined, "
                  f"{len(used_classes)} host classes referenced")
            if missing_classes:
                print(f"missing classes: {len(missing_classes)}")
                by_package: Counter[str] = Counter()
                for descriptor in missing_classes:
                    by_package[package_of(descriptor)] += 1
                for package, count in by_package.most_common():
                    print(f"  {count:3d}  {package}")
                print("\n  detail:")
                for descriptor in sorted(missing_classes):
                    methods = sorted(missing_classes[descriptor])
                    print(f"  {descriptor_name(descriptor)}")
                    for key in methods[:18]:
                        print(f"      {key}")
                    if len(methods) > 18:
                        print(f"      … {len(methods) - 18} more")
            if missing_methods:
                print(f"missing methods on registered classes: {len(missing_methods)}")
                for descriptor in sorted(missing_methods):
                    keys = sorted(missing_methods[descriptor])
                    print(f"  {descriptor_name(descriptor)}  ({len(keys)})")
                    for key in keys[:18]:
                        print(f"      {key}")
                    if len(keys) > 18:
                        print(f"      … {len(keys) - 18} more")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
