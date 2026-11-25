#!/bin/bash
# Assemble boot.img for the Debian 13 root.
#
# Needs : kernel-out/ (kernel job), rootfs.tar.gz (rootfs job), the stock
#         fastboot ROM (DTBO table + vendor_boot DTBs)
# Writes: out/native-boot/boot-liuqin-native.img + identity file
set -euo pipefail

PROJECT=${PROJECT:-$PWD/project}
KERNEL_OUT=${KERNEL_OUT:-$PWD/kernel-out}
ROM_DIR=${ROM_DIR:-$PWD/rom}
WORK=${WORK:-$PWD/bootwork}

say() { printf '\n==> %s\n' "$*"; }

say "project add-ons: mkbootimg + busybox + audio topology"
cd "$PROJECT"
# The googlesource archive hash is not stable across its caches; the two files
# the boot chain pins are, so verify those instead of the container.
if [ ! -f tools/local/aosp-mkbootimg/mkbootimg.py ]; then
	curl -fsSL "https://android.googlesource.com/platform/system/tools/mkbootimg/+archive/954bc3ead5e679005fddf3484d247f2557b3c2c9.tar.gz" \
		-o /tmp/mkbootimg.tar.gz
	mkdir -p tools/local/aosp-mkbootimg
	tar -xzf /tmp/mkbootimg.tar.gz -C tools/local/aosp-mkbootimg
fi
echo "37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c  tools/local/aosp-mkbootimg/mkbootimg.py" | sha256sum -c
echo "06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e  tools/local/aosp-mkbootimg/unpack_bootimg.py" | sha256sum -c
sh tools/fetch-busybox-arm64.sh >/dev/null

if [ ! -d ../audioreach-topology/.git ]; then
	git clone -q https://github.com/linux-msm/audioreach-topology.git ../audioreach-topology
	git -C ../audioreach-topology fetch -q origin 2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0
	git -C ../audioreach-topology checkout -q FETCH_HEAD
fi
mkdir -p out/audio-topology
AUDIOREACH_TOPOLOGY_DIR="$PWD/../audioreach-topology" \
	OUTPUT="$PWD/out/audio-topology/Xiaomi-Pad-6-Pro-tplg.bin" \
	sh tools/build-liuqin-audio-topology.sh

say "firmware pool"
cd "$OLDPWD"
python3 ci/pool.py

say "stock ROM inputs"
mkdir -p "$ROM_DIR"
# The ROM is 6.7 GB and the runner's scratch space is ~14 GB, so stream the
# tarball straight into tar and keep only the two images the boot chain needs.
# The Xiaomi CDN throttles single connections at times, so every attempt is
# bounded and the next mirror is tried when the stream stalls.
MIRRORS="
https://cdnorg.d.miui.com/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz
https://bigota.d.miui.com/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz
https://bn.d.miui.com/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz
"
if [ ! -f "$ROM_DIR/dtbo.img" ] || [ ! -f "$ROM_DIR/vendor_boot.img" ]; then
	for url in $MIRRORS; do
		echo "stock rom mirror: $url"
		set +e
		curl -fL --progress-bar --retry 3 --retry-delay 5 \
			--speed-limit 40000 --speed-time 120 --max-time 2700 \
			-A "Mozilla/5.0" "$url" |
			tar -xz -C "$ROM_DIR" --wildcards '*/dtbo.img' '*/vendor_boot.img'
		set -e
		if [ -n "$(find "$ROM_DIR" -name dtbo.img | head -1)" ] &&
			[ -n "$(find "$ROM_DIR" -name vendor_boot.img | head -1)" ]; then
			break
		fi
	done
fi
DTBO=$(find "$ROM_DIR" -name dtbo.img | head -1)
VB=$(find "$ROM_DIR" -name vendor_boot.img | head -1)
[ -n "$DTBO" ] && [ -n "$VB" ] || { echo "stock images not extracted" >&2; exit 1; }
python3 ci/extract-stock.py "$DTBO" "$VB" "$WORK/stock/dtbo" "$WORK/stock/vendor_boot/dtbs"

say "native root manifest + contract"
rm -rf "$WORK/native-root"
mkdir -p "$WORK/native-root"
tar -xzf rootfs.tar.gz -C "$WORK/native-root"
python3 - "$WORK/native-root" "$WORK/native-root.hashes" <<'PY'
import hashlib, sys
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
rows = []
for path in sorted(root.rglob("*")):
    if path.is_symlink() or not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    rows.append(f"{digest}  /{path.relative_to(root)}")
out.write_text("\n".join(rows) + "\n")
print(f"manifest: {len(rows)} files")
PY
chmod 0644 "$WORK/native-root.hashes"

say "boot image"
rm -rf out/native-boot
KERNEL_SOURCE=${KERNEL_SOURCE:-$PWD/linux-sm8450-liuqin} \
KERNEL_OUT=$KERNEL_OUT \
NATIVE_ROOT_HASHES=$WORK/native-root.hashes \
CONTRACT_MAKER=$PWD/ci/make-contract.py \
AUDIO_TOPOLOGY=$PROJECT/out/audio-topology/Xiaomi-Pad-6-Pro-tplg.bin \
FIRMWARE_POOL=$PWD/firmware-liuqin \
STOCK_OVERLAY_DIR=$WORK/stock/dtbo \
STOCK_BASE_DIR=$WORK/stock/vendor_boot/dtbs \
MKBOOTIMG_DIR=$PROJECT/tools/local/aosp-mkbootimg \
ROOT_FSCK_ROOT=$WORK/native-root \
SLOT_SUCCESS_GCC=aarch64-linux-gnu-gcc \
OUT_DIR=$PROJECT/out/native-boot \
	sh "$PROJECT/tools/build-liuqin-native-boot.sh"

ls -lh "$PROJECT/out/native-boot/boot-liuqin-native.img"
