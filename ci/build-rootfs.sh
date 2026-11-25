#!/bin/bash
# Build a Debian 13 (trixie) arm64 root filesystem for Xiaomi Pad 6 Pro.
#
# The upstream project ships an Ubuntu/GNOME root built from a pinned ISO and
# five device .debs.  This builder produces the equivalent Debian side:
#
#   Debian 13 arm64 (mmdebstrap)
#   + the project firmware closure (device/firmware, 197 files)
#   + the kernel modules built in the kernel job
#   + the denial Wayland desktop (arm64 .debs, see ci/denial)
#   + the native-root marker and /usr/share/liuqin identity files that the
#     project's initramfs stage 1 admits
#
# OUTPUT: $PWD/rootfs.tar.gz (extract at <LIUQIN_ROOT>/native-root)
set -euo pipefail

PROJECT=${PROJECT:-$PWD/project}
KERNEL_OUT=${KERNEL_OUT:-$PWD/kernel-out}
ROOT=${ROOT:-$PWD/rootfs}
JOBS=${JOBS:-$(nproc)}
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n==> %s\n' "$*"; }

say "mmdebstrap Debian 13 arm64"
rm -rf "$ROOT"
mmdebstrap --arch=arm64 --variant=minbase \
	--components=main,contrib,non-free-firmware \
	--include=$(cat ci/packages.txt) \
	trixie "$ROOT" http://deb.debian.org/debian

say "firmware closure"
mkdir -p "$ROOT/usr/lib/firmware"
cp -a "$PROJECT/device/firmware/usr/lib/firmware/." "$ROOT/usr/lib/firmware/"
find "$ROOT/usr/lib/firmware" -type f | wc -l

say "denial desktop packages"
cp ci/denial/*.deb "$ROOT/root/"
chroot "$ROOT" /bin/sh -c '
	set -e
	dpkg -i /root/denial-flutter-engine_0.6.8-1_arm64.deb /root/denial_0.6.8-1_arm64.deb || true
	apt-get -f install -y
	rm -f /root/*.deb
	deniald --version 2>/dev/null || true
'

say "kernel identity and modules"
KREL=$(cat "$KERNEL_OUT/include/config/kernel.release")
[ -n "$KREL" ]
mkdir -p "$ROOT/lib/modules/$KREL" "$ROOT/usr/share/liuqin"
cp -a "$KERNEL_OUT/modules/lib/modules/$KREL/." "$ROOT/lib/modules/$KREL/"
printf '%s\n' "$KREL" >"$ROOT/usr/share/liuqin/kernel.release"
chmod 0644 "$ROOT/usr/share/liuqin/kernel.release"
( cd "$ROOT/lib/modules/$KREL" && find . -type f | LC_ALL=C sort ) \
	>"$ROOT/usr/share/liuqin/kernel-modules.manifest"
chmod 0644 "$ROOT/usr/share/liuqin/kernel-modules.manifest"
chroot "$ROOT" depmod -a "$KREL"

say "base system configuration"
printf 'liuqin\n' >"$ROOT/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 liuqin\n' >"$ROOT/etc/hosts"
cat >"$ROOT/etc/fstab" <<'EOF'
LABEL=LIUQIN_ROOT / ext4 defaults,noatime 0 1
LABEL=LIUQIN_HOME /home ext4 defaults,noatime,nofail 0 2
EOF
chmod 0644 "$ROOT/etc/fstab" "$ROOT/etc/hostname" "$ROOT/etc/hosts"

say "denial autologin session"
mkdir -p "$ROOT/etc/sddm.conf.d"
cat >"$ROOT/etc/sddm.conf.d/10-liuqin.conf" <<'EOF'
[Autologin]
User=liuqin
Session=denial.desktop

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
EOF
ln -sfn /usr/lib/systemd/system/sddm.service "$ROOT/etc/systemd/system/display-manager.service"
ln -sfn /usr/lib/systemd/system/graphical.target "$ROOT/etc/systemd/system/default.target"
chroot "$ROOT" systemctl enable sddm.service NetworkManager.service bluetooth.service

say "human account"
chroot "$ROOT" /bin/sh -c '
	set -e
	useradd -m -u 1000 -s /bin/bash liuqin
	echo "liuqin:liuqin" | chpasswd
	for group in sudo video render input audio netdev bluetooth plugdev; do
		getent group "$group" >/dev/null && usermod -aG "$group" liuqin || true
	done
	echo "liuqin ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-liuqin
	chmod 0440 /etc/sudoers.d/90-liuqin
'

say "native root marker"
printf 'liuqin-native-root-v1\n' >"$ROOT/etc/liuqin-native-root"
chmod 0644 "$ROOT/etc/liuqin-native-root"
MARKER=$(sha256sum "$ROOT/etc/liuqin-native-root" | cut -d' ' -f1)
[ "$MARKER" = 4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b ] || {
	echo "marker hash mismatch: $MARKER" >&2
	exit 1
}

say "module options and services"
mkdir -p "$ROOT/etc/modprobe.d"
printf 'options ath11k_pci nohwcrypt=0\n' >"$ROOT/etc/modprobe.d/liuqin.conf"

say "archive"
( cd "$ROOT" && tar --numeric-owner --xattrs --acls -cpf - . ) | gzip -6 >rootfs.tar.gz
sha256sum rootfs.tar.gz
ls -lh rootfs.tar.gz
