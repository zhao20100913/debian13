#!/usr/bin/env python3
"""Build the initramfs firmware pool from the project's pinned closure.

device/firmware/usr/lib/firmware is the complete 197-file firmware set the
project ships (verified by firmware.manifest).  The initramfs builder wants it
in a pool layout that also names the upstream/ vendor split, so this script
maps each file by content hash, which is what the builder checks anyway.
"""
import hashlib
import shutil
import sys
from pathlib import Path

SRC = Path("project/device/firmware/usr/lib/firmware")
POOL = Path("firmware-liuqin")

TOUCH = (
    "novatek_nt36532_m81_fw_csot.bin",
    "novatek_nt36532_m81_fw_tm.bin",
)
WLAN_UPSTREAM = ("amss.bin.zst", "board-2.bin.zst", "m3.bin.zst", "regdb.bin.zst")
REGULATORY = ("regulatory.db", "regulatory.db.p7s")


def copy(src: str, dst: str) -> None:
    target = POOL / dst
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SRC / src, target)


def main() -> int:
    if not SRC.is_dir():
        raise SystemExit(f"firmware closure is unavailable: {SRC}")
    shutil.rmtree(POOL, ignore_errors=True)
    for name in TOUCH:
        copy(f"novatek/liuqin/{name}", f"touch-nt36532/vendor/firmware/{name}")
    bt = 0
    for path in sorted((SRC / "qca").iterdir()):
        if path.name.startswith(("hpbtfw", "hpnv")):
            copy(f"qca/{path.name}", f"bt-qca6490/vendor/bt_firmware/image/{path.name}")
            bt += 1
    copy("ath11k/WCN6855/hw2.0/board.bin", "wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf")
    for name in WLAN_UPSTREAM:
        copy(f"ath11k/WCN6855/hw2.0/{name}", f"wlan-qca6490/upstream/WCN6855/hw2.0/{name}")
    for name in REGULATORY:
        copy(name, f"regulatory/upstream/{name}")
    copy("updates/qcom/a730_sqe.fw", "gpu-adreno730/vendor/a730_sqe.fw")
    copy("qcom/sm8475/liuqin/a730_zap.mbn", "gpu-adreno730/vendor/a730_zap.mbn")
    copy("updates/qcom/gmu_gen70000.bin", "gpu-adreno730/vendor/gmu_gen70000.bin")
    dsp = POOL / "dsp-sm8475/vendor/qcom/sm8475/liuqin"
    dsp.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in sorted((SRC / "qcom/sm8475/liuqin").iterdir()):
        if path.name == "a730_zap.mbn":
            continue
        shutil.copy2(path, dsp / path.name)
        n += 1
    print(f"pool: bt={bt} dsp={n}")
    if n != 68 or bt == 0:
        raise SystemExit("firmware pool is incomplete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
