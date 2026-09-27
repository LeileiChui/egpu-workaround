#!/usr/bin/env bash
# egpu-up.sh — eGPU bring-up: rescan -> 清理重复 -> BAR0 校验 -> Gen3+HASD cap -> 加载 nvidia
#
# 幂等：已加载且可用时快速返回。任何一步失败都写状态并给出可读指引，不硬来。
# 需 root。退出码：0=UP，1=失败（见 /run/egpu/state），3=已有实例在跑。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${EGPU_CONF:-}"
if [ -z "$CONF" ]; then
  if [ -r /etc/egpu.conf ]; then CONF=/etc/egpu.conf; else CONF="$SELF_DIR/egpu.conf"; fi
fi
if [ ! -r "$CONF" ]; then
  printf 'egpu-up: ERROR: config not readable: %s\n' "$CONF" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$CONF"

PCI_ROOT="${PCI_ROOT:-/sys/bus/pci/devices}"
PCI_RESCAN="${PCI_RESCAN:-/sys/bus/pci/rescan}"
STATE_DIR="${STATE_DIR:-/run/egpu}"

log() { printf '[egpu] %s\n' "$*" >&2; command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" "$*"; }
set_state() { mkdir -p "$STATE_DIR"; printf '%s\n' "$1" >"$STATE_DIR/state"; }
get_state() { cat "$STATE_DIR/state" 2>/dev/null || echo UNKNOWN; }

list_gpu_bdfs() {
  local d v dv
  for d in "$PCI_ROOT"/*; do
    [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
    v=$(<"$d/vendor"); dv=$(<"$d/device")
    if [ "$v" = "0x$GPU_VID" ] && [ "$dv" = "0x$GPU_DID" ]; then
      basename "$(readlink -f "$d")"
    fi
  done
}

bar0_of() { awk 'NR==1{print $1}' "$PCI_ROOT/$1/resource" 2>/dev/null; }
bar0_zero() { local r; r=$(bar0_of "$1"); [ -z "$r" ] || [ "$r" = "0x0000000000000000" ]; }

parent_of() { basename "$(dirname "$(readlink -f "$PCI_ROOT/$1")")"; }

is_up() {
  lsmod 2>/dev/null | grep -q '^nvidia ' || return 1
  nvidia-smi >/dev/null 2>&1 || return 1
  return 0
}

# 当前已加载的 nvidia 是否带 RMPcieFLRPolicy=1（决定 teardown 能否安全卸载）
verify_regkey() {
  local v
  v=$(cat /sys/module/nvidia/parameters/NVreg_RegistryDwords 2>/dev/null || true)
  case "$v" in *RMPcieFLRPolicy=1*) return 0 ;; *) return 1 ;; esac
}

unload_nvidia() { modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null; }

# 等 GPU 出现；期间**周期性重发 rescan**（$RESCAN_RETRY_SEC，默认 3s）。
# 原因（2026-09-27 实测）：坞在 TB 层 authorize 之后，其 PCIe 隧道的枚举可能
# **晚到**（或需要再扫一次才出设备）。单次 rescan + 干等会漏掉 → 误判 NO_GPU。
# rescan 幂等，重发无副作用。
wait_for_gpu() { # $1 = seconds
  local deadline next_rescan now
  deadline=$(( $(date +%s) + ${1:-15} ))
  next_rescan=$(( $(date +%s) + ${RESCAN_RETRY_SEC:-3} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(list_gpu_bdfs | head -n1)" ] && return 0
    now=$(date +%s)
    if [ "$now" -ge "$next_rescan" ]; then
      echo 1 >"$PCI_RESCAN" 2>/dev/null || true
      next_rescan=$(( now + ${RESCAN_RETRY_SEC:-3} ))
    fi
    sleep 0.5
  done
  return 1
}

# 设备 config 是否可读（vendor != ffff）
reachable() {
  local v
  v=$(setpci -s "$1" 0.w 2>/dev/null) || return 1
  [ -n "$v" ] && [ "$v" != "ffff" ]
}

# ⚠️ 危险操作：移除 TB 交换机（JHL9480, 8086:5786）最靠上的那个 + rescan。
# 实测能救回 "链路半死" 的 GPU，但**可能把 dock 从 TB 总线踢掉**（导致 TB 设备 0-1 消失）。
# 因此：仅在 TB 设备仍注册、且显式允许（EGPU_ALLOW_SWITCH_REMOVE=1，默认允许）时执行；
#       执行后校验交换机是否恢复，未恢复就明确提示断电重插。
reenumerate_tb_switch() {
  if [ "${EGPU_ALLOW_SWITCH_REMOVE:-1}" != "1" ]; then
    log "switch remove 被禁用 (EGPU_ALLOW_SWITCH_REMOVE!=1)"
    return 1
  fi
  # C21 硬护栏：nvidia 未干净卸载时，remove 交换机 会卡在
  # device_release_driver_internal（D 状态不可恢复）。必须先确认无 nvidia。
  if lsmod 2>/dev/null | grep -q '^nvidia '; then
    log "nvidia 仍在加载（或半卸载），拒绝 switch remove（会卡死，见 C21）"
    return 1
  fi
  if ! ls /sys/bus/thunderbolt/devices/0-* >/dev/null 2>&1; then
    log "TB 设备未注册，跳过 switch remove"
    return 1
  fi
  local sw
  sw=$(for d in "$PCI_ROOT"/*; do
         [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
         [ "$(<"$d/vendor")" = "0x8086" ] && [ "$(<"$d/device")" = "0x5786" ] || continue
         basename "$(readlink -f "$d")"
       done | sort | head -n1)
  [ -n "$sw" ] || return 1
  log "移除 TB 交换机 $sw + rescan（危险：可能踢掉 dock）"
  echo 1 >"$PCI_ROOT/$sw/remove" 2>/dev/null || return 1
  sleep 2
  echo 1 >"$PCI_RESCAN" 2>/dev/null || true
  sleep 4
  if [ ! -d "$PCI_ROOT/$sw" ]; then
    log "!! 交换机 $sw 未恢复 —— dock PCIe 侧可能已被踢下 TB 总线，请【断电重插扩展坞】"
    return 1
  fi
  return 0
}

# 保证 GPU 及其父桥 config 可达；不行就重建 TB 交换机枚举。
#
# 注意（实测教训）：**不要用 reset_subordinate** —— 半死链路上它会卡死在
# `pci_bridge_wait_for_secondary_bus`（D 状态长等待）。正确顺序是：
#   先卸载 nvidia（GPU 不可达时卸载安全），再 switch remove（否则会卡在 C21）。
ensure_reachable() {
  local gpu="$1" p
  reachable "$gpu" && reachable "$(parent_of "$gpu")" && return 0
  p=$(parent_of "$gpu")
  log "GPU/父桥 config 不可达（$gpu / $p）"
  if lsmod 2>/dev/null | grep -q '^nvidia '; then
    log "先卸载 nvidia（GPU 不可达 → 卸载安全），再做 switch 重枚举"
    unload_nvidia || true
  fi
  reenumerate_tb_switch || return 1
  return 0
}

dedup_gpus() { # echo 保留的 BDF
  local -a all=()
  mapfile -t all < <(list_gpu_bdfs)
  [ "${#all[@]}" -eq 0 ] && return 1
  [ "${#all[@]}" -eq 1 ] && { printf '%s\n' "${all[0]}"; return 0; }
  local keep="" b
  for b in "${all[@]}"; do
    bar0_zero "$b" || keep="$b"
  done
  [ -z "$keep" ] && keep="${all[0]}"
  for b in "${all[@]}"; do
    [ "$b" = "$keep" ] && continue
    log "removing duplicate/stale GPU entry $b"
    echo 1 >"$PCI_ROOT/$b/remove" 2>/dev/null || true
  done
  sleep 1
  printf '%s\n' "$keep"
}

fix_bar0() { # $1 = gpu bdf；失败返回 1
  local gpu="$1" parent tries=0
  while bar0_zero "$gpu"; do
    tries=$((tries + 1))
    [ "$tries" -gt "${BAR_RETRY:-3}" ] && return 1
    parent=$(parent_of "$gpu")
    log "BAR0==0 on $gpu; remove parent $parent + rescan (try $tries)"
    echo 1 >"$PCI_ROOT/$parent/remove" 2>/dev/null || true
    sleep "${BAR_REMOVE_SLEEP:-8}"
    echo 1 >"$PCI_RESCAN" 2>/dev/null || true
    sleep 2
    gpu=$(list_gpu_bdfs | head -n1) || return 1
    [ -n "$gpu" ] || return 1
  done
  printf '%s\n' "$gpu"
}

# O1.1：把 GPU 父链（根口 → JHL9480 → … → GPU）的 PM 钉住：
#   power/control=on + d3cold_allowed=0，阻止 D3cold / autosuspend 打断 TB 隧道。
# 90-egpu.rules 已声明式设置；这里做兜底（防 udev 顺序/竞态）。幂等、失败只告警。
# 见 plan/egpu-optimization-plan.md O1.1。
pin_pm_path() { # $1 = gpu bdf
  local gpu="$1" d parent n=0 stuck=""
  local -a devs=()
  d="$gpu"
  while :; do
    devs+=("$d")
    parent=$(parent_of "$d")
    case "$parent" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:*) ;; *) break ;; esac
    d="$parent"
  done
  for d in "${devs[@]}"; do
    [ -e "$PCI_ROOT/$d" ] || continue
    n=$((n + 1))
    [ -w "$PCI_ROOT/$d/power/control" ] && printf 'on\n' >"$PCI_ROOT/$d/power/control" 2>/dev/null || true
    [ -w "$PCI_ROOT/$d/d3cold_allowed" ] && printf '0\n' >"$PCI_ROOT/$d/d3cold_allowed" 2>/dev/null || true
    # 读回校验：hot-add 的 pcieport 桥会在驱动绑定时把 power/control 设回 auto，
    # 故本函数必须在【所有重枚举之后】再跑一次（见 main 末尾）。
    if [ "$(cat "$PCI_ROOT/$d/power/control" 2>/dev/null)" != "on" ] || \
       [ "$(cat "$PCI_ROOT/$d/d3cold_allowed" 2>/dev/null)" != "0" ]; then
      stuck="$stuck $d"
    fi
  done
  log "PM 钉住 $n 个设备: ${devs[*]}"
  [ -n "$stuck" ] && log "PM 警告：以下设备未粘住（稍后会在末尾重试）:$stuck" || true
}

recover_hint() {
  log "恢复指引：该 GPU 已掉总线且软件无法复位。请【断开扩展坞电源 10-15 秒后重新上电】，"
  log "或重插雷电线；必要时重启主机（重启时不要插着 dock，重启后再插）。"
}

main() {
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { log "another egpu instance is running; abort"; exit 3; }

  if is_up; then
    log "already UP (nvidia loaded, nvidia-smi ok) — ensuring cap + PM"
    local g
    g=$(list_gpu_bdfs | head -n1)
    [ -n "$g" ] && pin_pm_path "$g" || true
    "$SELF_DIR/egpu-bridge-cap.sh" apply >&2 || true
    set_state UP
    exit 0
  fi

  # 走到这里说明 is_up 为假 → nvidia 虽然加载着但不可用。
  # 必须先卸载：① 让新参数生效（已加载时 modprobe 是空操作）
  #             ② 让后续 switch 重枚举不被卡住（C21）
  if lsmod 2>/dev/null | grep -q '^nvidia '; then
    if verify_regkey; then
      log "nvidia 已加载但当前不可用 → 卸载后重载"
      unload_nvidia || true
    else
      local g
      g=$(list_gpu_bdfs | head -n1)
      if [ -z "$g" ] || ! reachable "$g"; then
        log "nvidia 已加载、缺 regkey，但 GPU 不可达 → 卸载安全"
        unload_nvidia || true
      else
        log "警告：nvidia 已加载、缺 regkey 且 GPU 可达；为避免 FLR 挂死，跳过卸载（建议重启）"
      fi
    fi
  fi

  set_state STARTING
  log "PCI rescan"
  echo 1 >"$PCI_RESCAN" 2>/dev/null || true
  sleep "${RESCAN_SETTLE_SEC:-2}"

  if ! wait_for_gpu "${WAIT_GPU_SEC:-15}"; then
    # 二级恢复：重建 TB 交换机枚举
    reenumerate_tb_switch || true
    if ! wait_for_gpu "${WAIT_GPU_SEC:-15}"; then
      log "GPU ${GPU_VID}:${GPU_DID} 未出现"
      set_state NO_GPU
      recover_hint
      exit 1
    fi
  fi

  local gpu
  gpu=$(dedup_gpus) || { set_state NO_GPU; exit 1; }
  log "using GPU $gpu"

  # GPU/父桥可达性 + 分级恢复（reset_subordinate → switch remove）
  if ! ensure_reachable "$gpu"; then
    wait_for_gpu "${WAIT_GPU_SEC:-15}" || true
    gpu=$(dedup_gpus) || { set_state NO_GPU; recover_hint; exit 1; }
    ensure_reachable "$gpu" || { set_state NO_GPU; recover_hint; exit 1; }
  fi

  gpu=$(fix_bar0 "$gpu") || { set_state BAR_FAIL; recover_hint; exit 1; }
  log "BAR0 ok: $(bar0_of "$gpu")  (gpu=$gpu)"

  # O1.1：钉住 TB 路径 PM（兜底；udev 规则已声明式设置）
  pin_pm_path "$gpu" || true

  # cap —— 必须在加载 nvidia 之前
  if ! "$SELF_DIR/egpu-bridge-cap.sh" apply >&2; then
    set_state CAP_FAIL
    exit 1
  fi

  # 加载驱动；失败则二级恢复（重建 TB 交换机）后重试一次。
  # 触发场景：快速插拔后 dock↔GPU 链路“半死”——config 可读、BAR0 正常、cap 也能写，
  # 但驱动 MMIO 读 NV_PMC_BOOT_0 得 0xffffffff → "fallen off the bus"。实测
  # switch 重枚举能救回（DLActive 仍是假象）。
  log "modprobe nvidia ${NV_MODULE_OPTS}"
  # shellcheck disable=SC2086
  if ! modprobe nvidia ${NV_MODULE_OPTS}; then
    log "modprobe 失败 → 二级恢复（重建 TB 交换机枚举）后重试"
    if reenumerate_tb_switch; then
      wait_for_gpu "${WAIT_GPU_SEC:-15}" || true
      gpu=$(dedup_gpus) || { set_state NO_GPU; recover_hint; exit 1; }
      ensure_reachable "$gpu" || true
      "$SELF_DIR/egpu-bridge-cap.sh" apply >&2 || true
      # shellcheck disable=SC2086
      if modprobe nvidia ${NV_MODULE_OPTS}; then
        log "重试 modprobe 成功"
      else
        set_state DRIVER_FAIL
        recover_hint
        exit 1
      fi
    else
      set_state DRIVER_FAIL
      recover_hint
      exit 1
    fi
  fi

  local deadline=$(( $(date +%s) + ${DRV_WAIT_SEC:-10} ))
  while [ ! -e /dev/nvidia0 ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.5; done

  if nvidia-smi >/dev/null 2>&1; then
    # O1.1：**最后**再 assert 一次 PM —— 上面任何 switch 重枚举都会让 hot-add 的
    # pcieport 桥把 power/control 设回 auto；这里保证它成为最后的写者（否则 O1.1 失效）。
    pin_pm_path "$gpu" || true
    if ! verify_regkey; then
      log "警告：nvidia 未带 RMPcieFLRPolicy=1 加载（teardown 将拒绝卸载）"
    fi
    log "UP: $(nvidia-smi --query-gpu=name,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null)"
    set_state UP
    exit 0
  fi

  log "nvidia-smi 失败"
  set_state DRIVER_FAIL
  exit 1
}

case "${1:-}" in
  --status) printf 'state=%s\n' "$(get_state)" ;;
  ""|up)    main ;;
  *) printf 'usage: %s [up|--status]\n' "${0##*/}" >&2; exit 2 ;;
esac
