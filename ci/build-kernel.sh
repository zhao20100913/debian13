#!/bin/bash
# Build the pinned liuqin mainline kernel for Xiaomi Pad 6 Pro.
#
# Inputs : $PWD/project  (upstream xiaomipad-6pro-mainline checkout, patched)
# Outputs: $PWD/kernel-out (Image, DTB, modules, .config, System.map, vmlinux)
set -euo pipefail

PROJECT=${PROJECT:-$PWD/project}
KERNEL_SRC=${KERNEL_SRC:-$PWD/linux-sm8450-liuqin}
KERNEL_OUT=${KERNEL_OUT:-$PWD/kernel-out}
JOBS=${JOBS:-$(nproc)}

lock_commit=$(python3 -c "import json;print(json.load(open('$PROJECT/kernel/source.json'))['commit'])")
lock_branch=$(python3 -c "import json;print(json.load(open('$PROJECT/kernel/source.json'))['branch'])")
lock_repo=$(python3 -c "import json;print(json.load(open('$PROJECT/kernel/source.json'))['repo'])")

echo "kernel source: $lock_repo $lock_branch @ $lock_commit"

if [ ! -d "$KERNEL_SRC/.git" ]; then
	git clone --depth 1 --branch "$lock_branch" "$lock_repo" "$KERNEL_SRC"
fi
cd "$KERNEL_SRC"
git fetch --depth 1 origin "$lock_commit"
git checkout -q "$lock_commit"
git rev-parse HEAD

cd "$PROJECT"
CROSS_COMPILE=aarch64-linux-gnu- python3 tools/build-liuqin-kernel.py \
	--source "$KERNEL_SRC" --out "$KERNEL_OUT" --jobs "$JOBS"

ls -l "$KERNEL_OUT/arch/arm64/boot/Image"
ls -l "$KERNEL_OUT/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
cat "$KERNEL_OUT/include/config/kernel.release"
