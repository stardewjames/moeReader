#!/usr/bin/env python3
"""Generate deterministic offline fixtures for MoeReader tests.

Stdlib only. Running this script rewrites every fixture byte-for-byte.
"""

from __future__ import annotations

import io
import os
import struct
import tarfile
import zlib
import zipfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "MoeReaderTests", "Fixtures")
APP_RESOURCES = os.path.join(ROOT, "MoeReader", "Resources")
EPOCH = (2020, 1, 1, 0, 0, 0)


def png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    row = bytes(rgb) * width
    raw = b"".join(b"\x00" + row for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


RED = png(4, 6, (220, 40, 40))
GREEN = png(8, 10, (40, 180, 80))
BLUE = png(12, 14, (40, 80, 220))
COMIC_INFO = b"<?xml version=\"1.0\"?><ComicInfo><Title>Mini</Title></ComicInfo>\n"


def zinfo(name: str, method: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=EPOCH)
    info.compress_type = method
    info.create_system = 3
    info.external_attr = 0o644 << 16
    return info


def build_mini_cbz() -> None:
    path = os.path.join(FIXTURES, "mini.cbz")
    with zipfile.ZipFile(path, "w", allowZip64=True) as archive:
        archive.writestr(zinfo("page-2.png", zipfile.ZIP_DEFLATED), GREEN)
        archive.writestr(zinfo("page-10.png", zipfile.ZIP_STORED), BLUE)
        archive.writestr(zinfo("page-1.png", zipfile.ZIP_DEFLATED), RED)
        archive.writestr(zinfo("ComicInfo.xml", zipfile.ZIP_STORED), COMIC_INFO)
        archive.writestr(zinfo("__MACOSX/._page-1.png", zipfile.ZIP_STORED), b"junk")
        archive.writestr(zinfo(".DS_Store", zipfile.ZIP_STORED), b"junk")


def build_nopages_cbz() -> None:
    path = os.path.join(FIXTURES, "nopages.cbz")
    with zipfile.ZipFile(path, "w", allowZip64=True) as archive:
        archive.writestr(zinfo("ComicInfo.xml", zipfile.ZIP_STORED), COMIC_INFO)


def promote_central_entries_to_zip64(path: str) -> None:
    """Rewrite the central directory so every entry uses ZIP64 extra fields.

    zipfile only emits ZIP64 extras in the central directory when a size
    actually overflows, so force the 32-bit size/offset fields to their
    saturated values and append id 0x0001 extras carrying the real values.
    """
    with open(path, "rb") as handle:
        data = handle.read()

    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise RuntimeError("missing EOCD")
    (_sig, disk, cd_disk, disk_entries, total_entries,
     cd_size, cd_offset, comment_len) = struct.unpack_from("<IHHHHIIH", data, eocd)
    if disk or cd_disk or disk_entries != total_entries:
        raise RuntimeError("unexpected multi-disk archive")

    out = bytearray()
    pos = cd_offset
    entries = []
    for _ in range(total_entries):
        if data[pos:pos + 4] != b"PK\x01\x02":
            raise RuntimeError("missing central header")
        (name_len, extra_len, comment_len) = struct.unpack_from("<HHH", data, pos + 28)
        name = data[pos + 46:pos + 46 + name_len]
        extra = data[pos + 46 + name_len:pos + 46 + name_len + extra_len]
        comment = data[pos + 46 + name_len + extra_len:pos + 46 + name_len + extra_len + comment_len]
        (flags, method, _time, _date, crc, comp_size, uncomp_size,
         _name_len, _extra_len, _comment_len, _disk, _internal,
         _external, local_offset) = struct.unpack_from("<HHHHIIIHHHHHII", data, pos + 8)
        zip64_extra = struct.pack("<HH", 0x0001, 24) + struct.pack("<QQQ", uncomp_size, comp_size, local_offset)
        new_extra = extra + zip64_extra
        header = bytearray(data[pos:pos + 46])
        struct.pack_into("<I", header, 20, 0xFFFFFFFF)  # compressed size
        struct.pack_into("<I", header, 24, 0xFFFFFFFF)  # uncompressed size
        struct.pack_into("<I", header, 42, 0xFFFFFFFF)  # local header offset
        struct.pack_into("<H", header, 30, len(new_extra))
        out += header + name + new_extra + comment
        entries.append((flags, method, crc, comp_size, uncomp_size, local_offset, name))
        pos += 46 + name_len + extra_len + comment_len

    # ZIP64 EOCD + locator, then the classic EOCD.
    zip64_eocd_offset = cd_offset + len(out)
    zip64_eocd = struct.pack(
        "<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0,
        total_entries, total_entries, len(out), cd_offset,
    )
    locator = struct.pack("<IIQI", 0x07064B50, 0, zip64_eocd_offset, 1)
    new_eocd = bytearray(data[eocd:])
    struct.pack_into("<I", new_eocd, 12, len(out))
    prefix = data[:cd_offset]
    trailer = zip64_eocd + locator + bytes(new_eocd)
    with open(path, "wb") as handle:
        handle.write(prefix + bytes(out) + trailer)


def build_mini64_cbz() -> None:
    path = os.path.join(FIXTURES, "mini64.cbz")
    with zipfile.ZipFile(path, "w", allowZip64=True) as archive:
        with archive.open(zinfo("page-1.png", zipfile.ZIP_DEFLATED), "w", force_zip64=True) as handle:
            handle.write(RED)
        with archive.open(zinfo("page-2.png", zipfile.ZIP_STORED), "w", force_zip64=True) as handle:
            handle.write(GREEN)
    promote_central_entries_to_zip64(path)


def build_mini_cbt() -> None:
    path = os.path.join(FIXTURES, "mini.cbt")
    with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name, payload in (("page-2.png", GREEN), ("page-1.png", RED)):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mtime = 0
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(payload))


def main() -> None:
    os.makedirs(FIXTURES, exist_ok=True)
    os.makedirs(APP_RESOURCES, exist_ok=True)
    build_mini_cbz()
    build_mini64_cbz()
    build_nopages_cbz()
    build_mini_cbt()
    with open(os.path.join(FIXTURES, "mini.cbz"), "rb") as source:
        payload = source.read()
    with open(os.path.join(APP_RESOURCES, "mini.cbz"), "wb") as target:
        target.write(payload)


if __name__ == "__main__":
    main()
