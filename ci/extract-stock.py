#!/usr/bin/env python3
"""Extract the stock vendor_boot DTBs and the stock DTBO table from the ROM.

The project's boot image must export the symbols of the stock DTBO entries and
mirror the stock DTB identity, because the bootloader always applies its own
overlay to whatever DTB the boot image carries.  Those inputs come from the
retail fastboot ROM and are pinned by hash upstream.

  stock_overlay_dir  entry.NN          (44 files, 32-byte-entry DTBO format)
  stock_base_dir     dtb-NN.dtb        (14 files, from vendor_boot ramdisk)
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


def dump_dtbo(image: Path, out: Path) -> int:
    data = image.read_bytes()
    magic, total, header_size, count, entries_offset, _page, version = struct.unpack_from(">7I", data, 0)
    if magic != DTBO_MAGIC:
        raise SystemExit(f"not a DTBO image: {image} (magic {magic:#x})")
    if total > len(data):
        raise SystemExit("DTBO total_size exceeds the image")
    print(f"dtbo: version={version} entries={count} header={header_size}")
    out.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        off = entries_offset + index * 32
        size, dt_offset = struct.unpack_from(">2I", data, off)
        if dt_offset + size > total:
            raise SystemExit(f"DTBO entry {index} escapes the image")
        (out / f"entry.{index:02d}").write_bytes(data[dt_offset:dt_offset + size])
    return count


def decompress(payload: bytes) -> bytes:
    if payload[:2] == b"\x1f\x8b":
        return gzip.decompress(payload)
    if payload[:4] == b"\x04\x22\x4d\x18":
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
    if payload[:6] == b"070701" or payload[:6] == b"070702":
        return payload
    raise SystemExit(f"unknown ramdisk compression: {payload[:8].hex()}")


def dump_vendor_boot(image: Path, work: Path, out: Path) -> int:
    unpack = Path("project/tools/local/aosp-mkbootimg/unpack_bootimg.py")
    subprocess.run([sys.executable, str(unpack), "--boot_img", str(image), "--out", str(work)], check=True)
    ramdisk = next((work / name for name in (work / "vendor_ramdisk", work / "ramdisk")
                    if (work / name).is_file()), None)
    if ramdisk is None:
        raise SystemExit(f"vendor_boot ramdisk not found under {work}")
    payload = decompress(ramdisk.read_bytes())
    stage = work / "ramdisk-tree"
    stage.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cpio", "-idm", "--no-absolute-filenames"], cwd=stage,
                   input=payload, check=True)
    found = sorted(p for p in stage.rglob("*.dtb") if p.is_file())
    print(f"vendor_boot: {len(found)} dtbs")
    if len(found) != 14:
        raise SystemExit(f"expected 14 stock base DTBs, found {len(found)}")
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(found[2], out / "dtb-02.dtb")
    if sha256(out / "dtb-02.dtb") != DTB02_SHA256:
        matches = [p for p in found if sha256(p) == DTB02_SHA256]
        if len(matches) != 1:
            raise SystemExit("no single vendor_boot DTB matches the pinned dtb-02 hash")
        print(f"note: dtb-02 is {matches[0].name}, not the third in name order")
        found.remove(matches[0])
        found.insert(2, matches[0])
        shutil.copy2(matches[0], out / "dtb-02.dtb")
    for index, path in enumerate(found):
        shutil.copy2(path, out / f"dtb-{index:02d}.dtb")
    return len(found)


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
