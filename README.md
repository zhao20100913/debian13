# Debian 13 for Xiaomi Pad 6 Pro (liuqin)

用 GitHub Actions 为小米平板 6 Pro（`liuqin`，骁龙 8+ Gen 1 / SM8475）构建
主线 Linux + **Debian 13 (trixie)** + **denial** 桌面的镜像产物。

上游项目 [yzddmr6/xiaomipad-6pro-mainline](https://github.com/yzddmr6/xiaomipad-6pro-mainline)
发布的是 Ubuntu + GNOME；本仓库按它的 [BUILD.md](https://github.com/yzddmr6/xiaomipad-6pro-mainline/blob/main/docs/BUILD.md)
流程复用同一套内核、固件闭包、initramfs stage-1 和 boot.img 装配，只把用户态换成
Debian 13 + denial。

## 产物（[v0.1.0-debian13](https://github.com/zhao20100913/debian13/releases/tag/v0.1.0-debian13)）

| 文件 | 说明 |
|---|---|
| `boot.img` | 内核 Image + 设备树（含原厂 DTBO 符号表）+ 项目 initramfs，刷到 `boot_a` |
| `rootfs.tar.gz` | Debian 13 arm64 根文件系统，解到 `LIUQIN_ROOT` 分区的 `native-root/` |
| `kernel.release` | 内核版本串，用于核对 rootfs 与 boot.img 是否同批 |

## 任务

1. `kernel` — 按 `kernel/source.json` 锁定 commit（当前 `c25f056e`）交叉编译
   Image / DTB / 模块，构建脚本会核对最终 `.config` 的 sha256。
2. `rootfs` — mmdebstrap 出 Debian 13 arm64，装入：
   - 项目固件闭包（197 个文件，`device/firmware`）
   - 上一步的内核模块与 `/usr/share/liuqin/kernel.release`
   - denial 0.6.8 arm64（`ci/denial/`，上游只发 x86_64 二进制，这里是本机源码构建的包）
   - SDDM 自动登录 + `denial.desktop` 会话、`liuqin` 用户（密码 `liuqin`）
   - native-root 标记（stage-1 准入用）与 `/etc/fstab`
3. `boot` — 下载原厂 fastboot ROM，流式抽出 `dtbo.img` / `vendor_boot.img`，
   得到 44 个 DTBO 条目与 14 个原厂 base DTB；构建 AudioReach 拓扑、固件池、
   root 哈希清单和 admission contract，然后跑项目的 `build-liuqin-native-boot.sh`。
4. `release` — 打 tag 时把产物发布到 Release。

## 与上游的差异（`patches/`）

| 补丁 | 原因 |
|---|---|
| `0001-init-debian-root-admission.patch` | 上游 initramfs 的 native 准入写死 Ubuntu+GNOME 设备层（gdm3、hexagonrpcd、power-keyd…），Debian 根不可能满足；改为“标记 + 10 条 pin 哈希 + systemd 可执行”的校验，存储/分区/加密逻辑不动 |
| `0002-boot-debian-profile.patch` | 让 contract 生成器可替换；`WLAN_HSP2_TUPLE` 变成可选（免费 runner 磁盘放不下 `super.img`，拿不到 vendor 分区的 HSP2 固件时退回上游 WCN6855 固件并告警） |

## 安装

前置：平板已解锁 Bootloader，且已经用上游 v0.8.0 安装包完成过一次安装
（`linux_root` / `linux_home` 分区与 `native-root` 目录由此建立）。

```sh
# 1. 刷入新 boot（双系统布局从 A 槽启动）
fastboot flash boot_a boot.img
fastboot reboot bootloader

# 2. 或在已启动的上游 Ubuntu 里替换根文件系统
sudo umount /home || true
sudo mount /dev/disk/by-partlabel/linux_root /mnt
sudo rm -rf /mnt/native-root/* /mnt/native-root/.[!.]* 2>/dev/null
sudo tar -xzf rootfs.tar.gz -C /mnt/native-root --numeric-owner
sudo sync && sudo reboot
```

`/home` 在独立分区（`LIUQIN_HOME`）上，替换根不影响用户数据。

## 构建验证记录（v0.1.0-debian13）

- 内核：`c25f056e`，`.config` sha256 与 `kernel/source.json` 一致，
  `kernel.release = 6.17.0-rc1-liuqin-next20261112b-gc25f056e0c20`
- boot.img：`ANDROID!` v2 头、page 4096、Image.gz 18.1 MB、ramdisk 35.5 MB（gzip）
- boot.img 设备树：`__symbols__` 已导出，`model = "Xiaomi Pad 6 Pro"`
- initramfs：`/etc/liuqin-storage-mode=persistent`、`/etc/liuqin-root-profile=native`、
  native-root contract 首条 pin 指向 `/etc/liuqin-native-root`
- rootfs：Debian 13.8 arm64，`deniald 0.6.8` 可在该 root 内执行

## 已验证 / 未验证

构建期验证：内核 commit 与 `.config` 哈希、固件与拓扑哈希、DTBO 条目数（44）与
base DTB 数（14）、contract 与 root 哈希清单一致、`deniald --version` 在 Debian 13
arm64 上可执行。

**未验证**：真机启动、触摸/显示/Wi-Fi/蓝牙/传感器、SDDM 自动登录。这些需要平板实测。

## 已知限制

- 传感器栈、指纹、电源键守护、开发者模式 SSH 等上游 Ubuntu 设备层没有移植；
  denial 桌面可用，但自动旋转、指纹登录、magic keyboard 等功能缺失。
- 未带 `super.img` 里的 vendor HSP2 WLAN 固件时，Wi-Fi 用上游 WCN6855 固件，
  不保证冷启动稳定。
- 上游 initramfs 的 charger-mode 依赖内核模块与 libdrm，已按原样保留。
