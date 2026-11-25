#!/bin/bash
# Assemble boot.img for the Debian 13 root.
#
# Needs : kernel-out/ (kernel job), rootfs.tar.gz (rootfs job), the stock
#         fastboot ROM (DTBO table + vendor_boot DTBs)
# Writes: project/out/native-boot/boot-liuqin-native.img + identity file
set -euo pipefail

PROJECT=${PROJECT:-$PWD/project}
KERNEL_OUT=${KERNEL_OUT:-$PWD/kernel-out}
ROM_DIR=${ROM_DIR:-$PWD/rom}
WORK=${WORK:-$PWD/bootwork}
ROM_URL=${ROM_URL:-https://cdnorg.d.miui.com/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz}
MIRRORS=${MIRRORS:-"$ROM_URL
https://bigota.d.miui.com/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz
https://cdn-ota.azureedge.net/OS2.0.6.0.VMYCNXM/liuqin_images_OS2.0.6.0.VMYCNXM_20250318.0000.00_15.0_cn_c29f6de5df.tgz"}

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

say "native root manifest + contract"
rm -rf "$WORK/native-root"
mkdir -p "$WORK/native-root"
# The rootfs archive carries static /dev nodes (created by mmdebstrap as
# root); the manifest only needs regular files, and the fsck runtime only
# needs the distribution libraries.
tar -xzf rootfs.tar.gz -C "$WORK/native-root" --no-same-owner \
	--exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' 
python3 - "$WORK/native-root" "$WORK/native-root.hashes" <<'PY'
import hashlib, sys
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
rows = []
for path in sorted(root.rglob("*")):
    if path.is_symlink() or not path.is_file():
        continue
    rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  /{path.relative_to(root)}")
out.write_text("\n".join(rows) + "\n")
print(f"manifest: {len(rows)} files")
PY
chmod 0644 "$WORK/native-root.hashes"
rm -f rootfs.tar.gz

say "stock ROM images"
mkdir -p "$ROM_DIR"
stock_tgz=$ROM_DIR/liuqin_images.tgz
if [ ! -f "$ROM_DIR/dtbo.img" ] || [ ! -f "$ROM_DIR/vendor_boot.img" ]; then
	# The Xiaomi CDN throttles one connection to a crawl at times, and the
	# whole 6.7 GB has to be read to reach vendor_boot.img (it sorts behind
	# super.img).  Fetch 1 MiB-aligned ranges over many connections into a
	# preallocated file, then extract the two members.  Falls back to a plain
	# streaming download when the CDN refuses ranges.
	fetch_ranges() {
		local url=$1 size=$2 conns=16 chunk i start end
		rm -f "$stock_tgz"
		truncate -s "$size" "$stock_tgz"
		chunk=$(( ((size + conns - 1) / conns + 1048575) / 1048576 * 1048576 ))
		for ((i = 0; i < conns; i++)); do
			start=$(( i * chunk ))
			[ "$start" -lt "$size" ] || break
			end=$(( start + chunk - 1 ))
			[ "$end" -lt "$size" ] || end=$(( size - 1 ))
			curl -fsL --retry 4 --retry-delay 3 --speed-limit 20000 --speed-time 120 \
				-A "Mozilla/5.0" -r "$start-$end" "$url" |
				dd of="$stock_tgz" bs=1M seek=$((start / 1048576)) conv=notrunc status=none &
		done
		wait
	}
	for url in $MIRRORS; do
		echo "stock rom mirror: $url"
		size=$(curl -fsIL -A "Mozilla/5.0" --max-time 60 "$url" |
			awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -1)
		echo "content-length: ${size:-unknown}"
		case $size in ''|*[!0-9]*) continue ;; esac
		[ "$size" -gt 100000000 ] || continue
		if ! fetch_ranges "$url" "$size"; then
			echo "range download failed; trying the next mirror"
			continue
		fi
		set +e
		tar -xzf "$stock_tgz" -C "$ROM_DIR" --wildcards '*/dtbo.img' '*/vendor_boot.img' 2>/dev/null
		set -e
		if [ -n "$(find "$ROM_DIR" -name dtbo.img | head -1)" ] &&
			[ -n "$(find "$ROM_DIR" -name vendor_boot.img | head -1)" ]; then
			rm -f "$stock_tgz"
			break
		fi
		rm -f "$stock_tgz"
	done
fi

DTBO=$(find "$ROM_DIR" -name dtbo.img | head -1)
VB=$(find "$ROM_DIR" -name vendor_boot.img | head -1)
[ -n "$DTBO" ] && [ -n "$VB" ] || { echo "stock images not extracted" >&2; exit 1; }
ls -l "$DTBO" "$VB"
python3 ci/extract-stock.py "$DTBO" "$VB" "$WORK/stock/dtbo" "$WORK/stock/vendor_boot/dtbs"
rm -f "$DTBO" "$VB"

say "boot image"
rm -rf "$PROJECT/out/native-boot"
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
