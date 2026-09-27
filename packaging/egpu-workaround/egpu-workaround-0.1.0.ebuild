# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit systemd

DESCRIPTION="Thunderbolt/USB4 NVIDIA eGPU workaround (rescan + PCIe Gen3/HASD cap + delayed nvidia load)"
HOMEPAGE="https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979"
# Scripts/config-only local package; all sources are shipped in files/.
LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"
IUSE=""

# No SRC_URI: $S must still exist for the install phase.
S="${WORKDIR}"

RDEPEND="
	app-shells/bash
	sys-apps/coreutils
	sys-apps/kmod
	sys-apps/pciutils
	sys-apps/systemd
	sys-apps/util-linux
"

src_install() {
	# ---- 工具脚本 ----
	exeinto /usr/sbin
	doexe "${FILESDIR}"/egpu-up.sh \
	      "${FILESDIR}"/egpu-down.sh \
	      "${FILESDIR}"/egpu-bridge-cap.sh \
	      "${FILESDIR}"/egpu-status.sh

	# ---- systemd 单元（由 udev 触发，不 enable）----
	systemd_dounit "${FILESDIR}"/egpu-up.service "${FILESDIR}"/egpu-down.service

	# ---- udev 规则：TB 热插拔 → systemd ----
	insinto /usr/lib/udev/rules.d
	doins "${FILESDIR}"/90-egpu.rules

	# ---- modprobe.d：黑名单 + 强制 nvidia options（含依赖/别名加载）----
	insinto /etc/modprobe.d
	doins "${FILESDIR}"/50-egpu-nvidia.conf

	# ---- Portage INSTALL_MASK：隐藏 NVIDIA 图形入口文件（compute-only，C29）----
	#   /etc/portage/env/nvidia-no-graphics.conf     ← INSTALL_MASK 定义
	#   /etc/portage/package.env/nvidia-no-graphics  ← 关联 x11-drivers/nvidia-drivers
	#   目的：nvidia-drivers 无对应 USE flag，用 INSTALL_MASK 让它不装
	#         Vulkan ICD / implicit layer / VulkanSC / EGL / OpenCL 入口文件。
	#   前提：/etc/portage/package.env 需为“目录”形式（Gentoo 常见布局）。
	insinto /etc/portage/env
	insopts -m0644
	doins "${FILESDIR}"/nvidia-no-graphics.conf
	insinto /etc/portage/package.env
	newins "${FILESDIR}"/nvidia-no-graphics.package.env nvidia-no-graphics

	# ---- systemd sleep hook：挂起前卸载、恢复后 bring-up ----
	exeinto /usr/lib/systemd/system-sleep
	newexe "${FILESDIR}"/egpu-sleep.sh 50-egpu

	# ---- 默认配置（/etc 受 CONFIG_PROTECT 保护）----
	insinto /etc
	insopts -m0644
	doins "${FILESDIR}"/egpu.conf
	dodoc "${FILESDIR}"/egpu.conf
}
