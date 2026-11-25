#!/usr/bin/env python3
"""Generate the stage-1 root admission contract for the Debian root.

The upstream generator (tools/lib/build-root-contract.py --profile native) pins
the Ubuntu + GNOME device layer: hexagonrpcd, ssccli, power-keyd, the storage
guard units and so on.  A Debian 13 root does not carry that layer, so this
generator pins the files the Debian build actually owns and that must not
change between the initramfs and the root tree:

    the native-root marker, the kernel identity, the pinned firmware, the
    denial desktop binaries and the display-manager/fstab configuration.

Every pin is taken from the assembled root's hash manifest, so the initramfs
and the root can never describe different trees.
"""
import sys
from pathlib import Path

PINS = (
    "/etc/liuqin-native-root",
    "/etc/fstab",
    "/etc/sddm.conf.d/10-liuqin.conf",
    "/usr/bin/denial-session",
    "/usr/bin/deniald",
    "/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_csot.bin",
    "/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_tm.bin",
    "/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin",
    "/usr/lib/systemd/system/sddm.service",
    "/usr/share/liuqin/kernel-modules.manifest",
    "/usr/share/liuqin/kernel.release",
)


def main() -> int:
    manifest, output = Path(sys.argv[1]), Path(sys.argv[2])
    hashes = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        digest, _, rel = line.partition("  ")
        if rel:
            hashes[rel] = digest
    lines = ["LIUQIN_NATIVE_ROOT_CONTRACT_V1"]
    missing = []
    for rel in PINS:
        if rel not in hashes:
            missing.append(rel)
            continue
        lines.append(f"{hashes[rel]}  {rel}")
    if missing:
        raise SystemExit("contract pins missing from the root manifest: " + ", ".join(missing))
    if len(lines) - 1 < 9:
        raise SystemExit("contract must carry at least 9 pins")
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    output.chmod(0o644)
    print(f"contract: {len(lines) - 1} pins -> {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
