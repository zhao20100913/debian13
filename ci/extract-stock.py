#!/usr/bin/env python3
"""Extract the stock vendor_boot DTBs and the stock DTBO table from the ROM.

The project's boot image must export the symbols of the stock DTBO entries and
mirror the stock DTB identity, because the bootloader always applies its own
overlay to whatever DTB the boot image carries.  Those inputs come from the
retail fastboot ROM and are pinned by hash upstream.

  stock_overlay_dir  entry.NN          (44 files, DTBO table from dtbo.img)
  stock_base_dir     dtb-NN.dtb        (14 files, vendor_boot dtb table)
"""
import gzip
import hashlib
import lzma
import shutil
import struct
import subprocess
import sys
from pathlib import Path

DTBO_MAGIC = 0xD7B7AB1E
DTB02_SHA256 = "527344cd52497d0b8b9311f1ab82ac3418b86b95c25e7786890f38f40054e467"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dtbo_entries(data: bytes, label: str):
    """Parse a v1 DTBO table header and yield each entry's bytes."""
    if len(data) < 32:
        raise SystemExit(f"{label}: file is too short to be a DTBO table")
    if struct.unpack_from(">I", data, 0)[0] != DTBO_MAGIC:
        return None
    (magic, total, header_size, entry_size, count, entries_offset,
     page_size, version) = struct.unpack_from(">8I", data, 0)
    print(f"{label}: version={version} entries={count} entry_size={entry_size} "
          f"header={header_size} page={page_size} total={total}")
    if entry_size != 32:
        print(f"{label}: entry size {entry_size} is not the classic 32 bytes; "
              "compressed entries are not supported")
    entries = []
    for index in range(count):
        off = entries_offset + index * entry_size
        size, offset = struct.unpack_from(">2I", data, off)
        if offset + size > len(data):
            raise SystemExit(f"{label}: entry {index} escapes the image")
        entries.append(data[offset:offset + size])
    return entries


def dump_dtbo(image: Path, out: Path) -> int:
    entries = dtbo_entries(image.read_bytes(), "dtbo.img")
    if entries is None:
        raise SystemExit(f"not a DTBO image: {image}")
    out.mkdir(parents=True, exist_ok=True)
    for index, payload in enumerate(entries):
        (out / f"entry.{index:02d}").write_bytes(payload)
    return len(entries)


def decompress(payload: bytes) -> bytes:
    if payload[:2] == b"\x1f\x8b":
        return gzip.decompress(payload)
    if payload[:4] in (b"\x04\x22\x4d\x18", b"\x02\x21\x4c\x18"):
        # LZ4 frame, and the legacy frame Qualcomm uses for vendor_boot.
        return subprocess.run(["lz4", "-d", "-c"], input=payload, check=True,
                              stdout=subprocess.PIPE).stdout
    if payload[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(payload)
    if payload[:4] == b"\x28\xb5\x2f\xfd":
        return subprocess.run(["zstd", "-d", "-c"], input=payload, check=True,
                              stdout=subprocess.PIPE).stdout
    if payload[:3] == b"BZh":
        import bz2
        return bz2.decompress(payload)
    if payload[:6] in (b"070701", b"070702"):
        return payload
    raise SystemExit(f"unknown ramdisk compression: {payload[:8].hex()}")


def order_bases(found, out: Path, label: str) -> int:
    if len(found) != 14:
        raise SystemExit(f"{label}: expected 14 stock base DTBs, found {len(found)}")
    out.mkdir(parents=True, exist_ok=True)
    hashes = {path: sha256(path) for path in found}
    match = [path for path in found if hashes[path] == DTB02_SHA256]
    if len(match) == 1 and found.index(match[0]) != 2:
        print(f"{label}: dtb-02 is {match[0].name}, reordering")
        found.remove(match[0])
        found.insert(2, match[0])
    elif len(match) != 1:
        raise SystemExit(f"{label}: no single base DTB matches the pinned dtb-02 hash")
    for index, path in enumerate(found):
        shutil.copy2(path, out / f"dtb-{index:02d}.dtb")
    print(f"{label}: {len(found)} base DTBs written")
    return len(found)


def dump_vendor_boot(image: Path, work: Path, out: Path) -> int:
    unpack = Path("project/tools/local/aosp-mkbootimg/unpack_bootimg.py")
    subprocess.run([sys.executable, str(unpack), "--boot_img", str(image),
                    "--out", str(work)], check=True)
    for path in sorted(work.iterdir()):
        print(f"vendor_boot part: {path.name} {path.stat().st_size}")

    # Qualcomm puts the base DTBs in the image's dtb section, itself a DTBO
    # table.  Some builds instead ship them in the vendor ramdisk as plain
    # files; accept either, preferring the table.
    table = work / "dtb"
    if table.is_file():
        entries = dtbo_entries(table.read_bytes(), "vendor_boot dtb")
        if entries is not None:
            stage = work / "dtb-entries"
            stage.mkdir(parents=True, exist_ok=True)
            found = []
            for index, payload in enumerate(entries):
                path = stage / f"dtb-{index:02d}.dtb"
                path.write_bytes(payload)
                found.append(path)
            if len(found) == 14:
                return order_bases(found, out, "vendor_boot dtb table")
            print(f"vendor_boot dtb table has {len(found)} entries, not 14; "
                  "falling back to the vendor ramdisk")

    ramdisk = work / "vendor_ramdisk"
    if not ramdisk.is_file():
        candidates = sorted(p for p in work.iterdir()
                            if p.is_file() and p.name.startswith("vendor_ramdisk"))
        if not candidates:
            candidates = sorted(p for p in work.iterdir()
                                if p.is_file() and "ramdisk" in p.name
                                and "-by-name" not in p.name)
        if not candidates:
            raise SystemExit(f"vendor_boot ramdisk not found under {work}")
        ramdisk = candidates[0]
        print(f"vendor_boot ramdisk: {ramdisk.name}")
    payload = decompress(ramdisk.read_bytes())
    stage = work / "ramdisk-tree"
    stage.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cpio", "-idm", "--no-absolute-filenames"], cwd=stage,
                   input=payload, check=True)
    found = sorted(p for p in stage.rglob("*.dtb") if p.is_file())
    print(f"vendor_ramdisk: {len(found)} dtbs")
    return order_bases(found, out, "vendor_ramdisk")


def main() -> int:
    dtbo, vendor_boot, overlay_dir, base_dir = map(Path, sys.argv[1:5])
    work = base_dir.parent / "vendor_boot-work"
    shutil.rmtree(overlay_dir, ignore_errors=True)
    shutil.rmtree(base_dir, ignore_errors=True)
    shutil.rmtree(work, ignore_errors=True)
    count = dump_dtbo(dtbo, overlay_dir)
    if count != 44:
        raise SystemExit(f"expected 44 stock DTBO entries, found {count}")
    dump_vendor_boot(vendor_boot, work, base_dir)
    print("stock inputs ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
