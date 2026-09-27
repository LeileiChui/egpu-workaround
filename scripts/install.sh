#!/usr/bin/env bash
# install.sh — 把 eGPU workaround 作为 Gentoo local overlay 包安装：
#   app-misc/egpu-workaround
#
# 组成：
#   packaging/egpu-workaround/<PN>-<PV>.ebuild   ebuild（源）
#   packaging/egpu-workaround/metadata.xml
#   packaging/egpu-workaround/files/             静态文件（udev 规则、systemd 单元）
#   scripts/*.sh + scripts/egpu.conf             运行时脚本（安装时同步进 files/）
#
# 安装后由 Portage 管理：
#   /usr/sbin/egpu-{up,down,bridge-cap}.sh
#   /usr/lib/systemd/system/egpu-{up,down}.service
#   /usr/lib/udev/rules.d/90-egpu.rules
#   /usr/lib/systemd/system-sleep/50-egpu
#   /etc/egpu.conf   (CONFIG_PROTECT)
#
# 需 root。卸载：./uninstall.sh 或 emerge -C app-misc/egpu-workaround
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SELF_DIR")"
PKG_SRC="$PROJ_DIR/packaging/egpu-workaround"

PN="egpu-workaround"
PV="0.1.0"
OVERLAY="${OVERLAY:-/var/db/repos/local}"
DEST="$OVERLAY/app-misc/$PN"

[ "$(id -u)" = "0" ] || { echo "install: 需要 root" >&2; exit 1; }
[ -r "$PKG_SRC/$PN-$PV.ebuild" ] || { echo "install: 找不到 $PKG_SRC/$PN-$PV.ebuild" >&2; exit 1; }

echo ">> 部署到 overlay: $DEST"
mkdir -p "$DEST/files"

# ebuild + metadata
install -m644 "$PKG_SRC/$PN-$PV.ebuild" "$DEST/$PN-$PV.ebuild"
install -m644 "$PKG_SRC/metadata.xml"   "$DEST/metadata.xml"

# 静态文件：udev 规则 + systemd 单元 + modprobe.d + Portage INSTALL_MASK 片段
install -m644 "$PKG_SRC/files/90-egpu.rules"       "$DEST/files/90-egpu.rules"
install -m644 "$PKG_SRC/files/egpu-up.service"     "$DEST/files/egpu-up.service"
install -m644 "$PKG_SRC/files/egpu-down.service"   "$DEST/files/egpu-down.service"
install -m644 "$PKG_SRC/files/50-egpu-nvidia.conf" "$DEST/files/50-egpu-nvidia.conf"
install -m644 "$PKG_SRC/files/nvidia-no-graphics.conf"         "$DEST/files/nvidia-no-graphics.conf"
install -m644 "$PKG_SRC/files/nvidia-no-graphics.package.env"  "$DEST/files/nvidia-no-graphics.package.env"

# 运行时脚本 + 默认配置
install -m755 \
	"$SELF_DIR/egpu-up.sh" \
	"$SELF_DIR/egpu-down.sh" \
	"$SELF_DIR/egpu-bridge-cap.sh" \
	"$SELF_DIR/egpu-status.sh" \
	"$SELF_DIR/egpu-sleep.sh" \
	"$DEST/files/"
install -m644 "$SELF_DIR/egpu.conf" "$DEST/files/"

echo ">> 生成 Manifest"
( cd "$DEST" && ebuild "$PN-$PV.ebuild" manifest )

echo ">> emerge app-misc/$PN"
emerge -v "app-misc/$PN"
