#!/usr/bin/env bash
# egpu-down.sh — eGPU tear-down（卸载 nvidia 模块）
#
# 背景：历史上在本机 TB eGPU 上 `modprobe -r nvidia` 会在 `nv_trigger_gpu_flr` /
# `RmShutdownAdapter` / `acpi_remove_notify_handler` 处 **D 状态挂死**（C11）。
# 根因是驱动在 remove 路径触发 PCIe FLR over TB。
#
# 已找到纯用户态解法：加载时带 `NVreg_RegistryDwords=RMPcieFLRPolicy=1`
# （NVIDIA 官方 regkey，见 plan/egpu-flr-avoidance.md）。E2 实测：
# 带该 regkey 后 `modprobe -r` 2 秒完成，不再挂死。
#
# 因此本脚本：**仅当当前已加载的模块确实带 RMPcieFLRPolicy=1 时才卸载**；
# 否则不卸载（避免挂死），除非显式 --force-unload。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${EGPU_CONF:-}"
if [ -z "$CONF" ]; then
  if [ -r /etc/egpu.conf ]; then CONF=/etc/egpu.conf; else CONF="$SELF_DIR/egpu.conf"; fi
fi
if [ ! -r "$CONF" ]; then
  printf 'egpu-down: ERROR: config not readable: %s\n' "$CONF" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$CONF"
STATE_DIR="${STATE_DIR:-/run/egpu}"
LOG_TAG="${LOG_TAG:-egpu}"

log() { printf '[egpu] %s\n' "$*" >&2; command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" "$*"; }

regkey_ok() {
  local v
  v=$(cat /sys/module/nvidia/parameters/NVreg_RegistryDwords 2>/dev/null || true)
  case "$v" in *RMPcieFLRPolicy=1*) return 0 ;; *) return 1 ;; esac
}

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another egpu instance is running; abort"; exit 3; }

if ! lsmod 2>/dev/null | grep -q '^nvidia '; then
  log "nvidia 未加载"
  printf 'DOWN\n' >"$STATE_DIR/state"
  exit 0
fi

if regkey_ok || [ "${1:-}" = "--force-unload" ]; then
  [ "${1:-}" = "--force-unload" ] && log "!! --force-unload：无视 regkey 强制卸载"
  log "卸载 nvidia（FLR 已被 RMPcieFLRPolicy=1 禁用，安全）"
  if modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/tmp/egpu-down.err; then
    log "nvidia 模块已卸载"
    printf 'DOWN\n' >"$STATE_DIR/state"
    exit 0
  fi
  log "卸载失败"
  sed 's/^/  /' /tmp/egpu-down.err >&2 2>/dev/null || true
  printf 'DOWN_FAIL\n' >"$STATE_DIR/state"
  exit 1
fi

log "当前 nvidia 未带 RMPcieFLRPolicy=1 加载 → 卸载会挂死在 FLR，已跳过。"
log "请用 scripts/egpu-up.sh 重新加载（带 regkey），或用 --force-unload 冒险。"
printf 'DOWN_KEPT\n' >"$STATE_DIR/state"
exit 0
