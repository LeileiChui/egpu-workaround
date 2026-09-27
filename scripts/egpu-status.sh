#!/usr/bin/env bash
# egpu-status.sh — eGPU 分层健康审计（只读，不修改任何状态）
#
# 用法:
#   egpu-status.sh        # 审计
#   egpu-status.sh -v     # 附带细节
#
# 退出码: 0=全部 OK；1=有 WARN；2=有 FAIL（供脚本/监控使用）
#
# 层：状态 → GPU/BAR0 → BAR1 → 链路 cap → nvidia+regkey → nvidia-smi
#     → TB 路径 PM（O1.1 验收）→ audio → 内核日志 Xid
# 见 plan/egpu-optimization-plan.md（O0.2）。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${EGPU_CONF:-}"
if [ -z "$CONF" ]; then
  if [ -r /etc/egpu.conf ]; then CONF=/etc/egpu.conf; else CONF="$SELF_DIR/egpu.conf"; fi
fi
[ -r "$CONF" ] && . "$CONF"

PCI_ROOT="${PCI_ROOT:-/sys/bus/pci/devices}"
STATE_DIR="${STATE_DIR:-/run/egpu}"
GPU_VID="${GPU_VID:-10de}"
GPU_DID="${GPU_DID:-2d04}"
CAP_TARGET_SPEED="${CAP_TARGET_SPEED:-3}"
CAP_SET_HASD="${CAP_SET_HASD:-1}"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
  C_INFO=$'\033[36m'; C_B=$'\033[1m'; C_R=$'\033[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_INFO=; C_B=; C_R=
fi

OK_N=0; WARN_N=0; FAIL_N=0
ok()   { printf '  %s[OK]%s   %s\n'   "$C_OK"   "$C_R" "$*"; OK_N=$((OK_N+1)); }
warn() { printf '  %s[WARN]%s %s\n'   "$C_WARN" "$C_R" "$*"; WARN_N=$((WARN_N+1)); }
fail() { printf '  %s[FAIL]%s %s\n'   "$C_FAIL" "$C_R" "$*"; FAIL_N=$((FAIL_N+1)); }
info() { printf '  %s[INFO]%s %s\n'   "$C_INFO" "$C_R" "$*"; }
sect() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_R"; }
dbg()  { [ "$VERBOSE" = 1 ] && printf '        %s\n' "$*"; return 0; }

read_w() { setpci -s "$1" "$2" 2>/dev/null; }
is_bdf() { [[ "$1" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; }
parent_of() { basename "$(dirname "$(readlink -f "$PCI_ROOT/$1")")"; }

find_gpu() {
  local d v dv
  for d in "$PCI_ROOT"/*; do
    [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
    v=$(<"$d/vendor"); dv=$(<"$d/device")
    [ "$v" = "0x$GPU_VID" ] && [ "$dv" = "0x$GPU_DID" ] || continue
    basename "$(readlink -f "$d")"; return 0
  done
  return 1
}
reachable() {
  local v
  v=$(setpci -s "$1" 0.w 2>/dev/null) || return 1
  [ -n "$v" ] && [ "$v" != "ffff" ]
}
bar0_of() { awk 'NR==1{print $1}' "$PCI_ROOT/$1/resource" 2>/dev/null; }
# 沿 GPU 父链收集设备（含 GPU 自身），从上层到下层
chain_of() {
  local d="$1" out=() p
  out+=("$d")
  while :; do
    p=$(parent_of "$d")
    is_bdf "$p" || break
    out=("$p" "${out[@]}")
    d="$p"
  done
  printf '%s\n' "${out[@]}"
}

# ------------------------------------------------------------------ 0. 状态
sect "0. 运行状态"
if [ -r "$STATE_DIR/state" ]; then
  st=$(<"$STATE_DIR/state")
  if [ "$st" = "UP" ]; then ok "state=UP"; else warn "state=$st（期望 UP）"; fi
else
  warn "$STATE_DIR/state 不存在（egpu-up.sh 尚未运行？）"
fi
if [ -e "$STATE_DIR/lock" ]; then
  if command -v fuser >/dev/null 2>&1 && fuser "$STATE_DIR/lock" >/dev/null 2>&1; then
    warn "有 egpu 实例正在运行（$STATE_DIR/lock 被占用）"
  else
    ok "无其它 egpu 实例持有 lock"
  fi
fi

# ------------------------------------------------------- 1. GPU 存在 + BAR0
sect "1. GPU 与 BAR0"
GPU=""
if GPU=$(find_gpu); then
  ok "GPU ${GPU_VID}:${GPU_DID} 存在 @ $GPU"
  if reachable "$GPU"; then
    ok "GPU config 可达"
  else
    fail "GPU config 不可达（读回 ffff）"
  fi
  b0=$(bar0_of "$GPU")
  if [ -n "$b0" ] && [ "$b0" != "0x0000000000000000" ] && [ "$b0" != "0x0" ]; then
    ok "BAR0=$b0"
  else
    fail "BAR0 未分配（$b0）"
  fi
  BRIDGE=$(parent_of "$GPU")
  if reachable "$BRIDGE"; then ok "父桥 $BRIDGE config 可达"; else warn "父桥 $BRIDGE config 不可达"; fi
else
  fail "GPU ${GPU_VID}:${GPU_DID} 不在 PCI 总线上"
fi

# ------------------------------------------------------------------ 2. BAR1
sect "2. BAR1 / ReBAR"
if [ -n "$GPU" ]; then
  read -r b1s b1e _ < <(awk 'NR==2{print $1, $2}' "$PCI_ROOT/$GPU/resource" 2>/dev/null)
  if [ -n "${b1s:-}" ] && [ -n "${b1e:-}" ]; then
    sz=$(( (16#${b1e#0x}) - (16#${b1s#0x}) + 1 ))
    size_h=$(( sz / 1048576 ))MiB
    [ $(( sz / 1073741824 )) -ge 1 ] && size_h=$(( sz / 1073741824 ))GiB
    info "BAR1 $b1s–$b1e = $size_h"
  fi
  [ -e "$PCI_ROOT/$GPU/resource1_resize" ] && dbg "ReBAR 可支持: $(cat "$PCI_ROOT/$GPU/resource1_resize" 2>/dev/null)"
fi

# --------------------------------------------------------------- 3. 链路 cap
sect "3. 链路封顶（Gen${CAP_TARGET_SPEED} + HASD）"
if [ -n "$GPU" ] && reachable "$GPU"; then
  for dev in "$(parent_of "$GPU")" "$GPU"; do
    lc2=$(read_w "$dev" "CAP_EXP+0x30.W")
    st=$(read_w "$dev" "CAP_EXP+0x12.W")
    if [ -z "$lc2" ]; then warn "$dev LnkCtl2 不可读"; continue; fi
    i=$((0x$lc2)); s=$((0x${st:-0}))
    tgt=$(( i & 0xF )); hasd=$(( (i >> 5) & 1 ))
    spd=$(( s & 0xF )); wid=$(( (s >> 4) & 0x3F ))
    line="LnkCtl2=0x$lc2 target=Gen$tgt hasd=$hasd | LnkSta Gen$spd x$wid"
    if [ "$tgt" = "$CAP_TARGET_SPEED" ] && [ "$hasd" = "$CAP_SET_HASD" ]; then
      ok "$dev $line"
    else
      fail "$dev $line（期望 target=Gen$CAP_TARGET_SPEED hasd=$CAP_SET_HASD）"
    fi
  done
else
  info "跳过（GPU 不可用）"
fi

# ------------------------------------------------- 4. nvidia 模块 + regkey
sect "4. nvidia 模块与参数"
if lsmod 2>/dev/null | grep -q '^nvidia '; then
  ok "nvidia 已加载（$(cat /sys/module/nvidia/version 2>/dev/null || echo '?')）"
  regkey=$(cat /sys/module/nvidia/parameters/NVreg_RegistryDwords 2>/dev/null || true)
  case "$regkey" in
    *RMPcieFLRPolicy=1*) ok "NVreg_RegistryDwords 含 RMPcieFLRPolicy=1（teardown 可安全卸载）" ;;
    *) fail "NVreg_RegistryDwords=\"$regkey\" 缺 RMPcieFLRPolicy=1（egpu-down.sh 将拒绝卸载）" ;;
  esac
  dpm=$(cat /sys/module/nvidia/parameters/NVreg_DynamicPowerManagement 2>/dev/null || echo '?')
  if [ "$dpm" = "0" ] || [ "$dpm" = "0x00" ]; then ok "NVreg_DynamicPowerManagement=$dpm"; else warn "NVreg_DynamicPowerManagement=$dpm（期望 0）"; fi
else
  warn "nvidia 未加载（eGPU 未 bring-up？）"
fi

# --------------------------------------------------------- 5. nvidia-smi
sect "5. nvidia-smi"
if lsmod 2>/dev/null | grep -q '^nvidia ' && [ -n "$GPU" ]; then
  out=$(timeout 15 nvidia-smi --query-gpu=name,pcie.link.gen.current,pcie.link.width.current \
        --format=csv,noheader 2>&1)
  if printf '%s' "$out" | grep -qE '^[^,]+,'; then
    ok "nvidia-smi: $(printf '%s' "$out" | head -1)"
  else
    fail "nvidia-smi 失败：$(printf '%s' "$out" | head -1)"
  fi
else
  info "跳过（nvidia 未加载或 GPU 不在）"
fi

# ------------------------------------------- 6. TB 路径 PM（O1.1 验收）
sect "6. TB 路径 PM 钉住（power/control=on, d3cold_allowed=0）"
if [ -n "$GPU" ]; then
  bad=(); n=0
  while IFS= read -r dev; do
    [ -e "$PCI_ROOT/$dev" ] || continue
    n=$((n+1))
    pc=$(cat "$PCI_ROOT/$dev/power/control" 2>/dev/null || echo '?')
    d3=$(cat "$PCI_ROOT/$dev/d3cold_allowed" 2>/dev/null || echo '?')
    dbg "$dev power/control=$pc d3cold_allowed=$d3"
    { [ "$pc" = "on" ] && [ "$d3" = "0" ]; } || bad+=("$dev(pc=$pc,d3=$d3)")
  done < <(chain_of "$GPU")
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "父链 $n 个设备均已钉住（$(chain_of "$GPU" | tr '\n' ' '))"
  else
    warn "未钉住：${bad[*]}  → 由 90-egpu.rules 的 PM 规则 / egpu-up.sh 的 pin_pm_path 设置"
  fi
else
  info "跳过（GPU 不在）"
fi

# ---------------------------------------------------------------- 7. audio
sect "7. GPU audio 功能"
if [ -n "$GPU" ]; then
  audio="${GPU%.*}.1"
  if [ -e "$PCI_ROOT/$audio" ]; then
    drv=$(basename "$(readlink -f "$PCI_ROOT/$audio/driver" 2>/dev/null)" 2>/dev/null || true)
    ov=$(cat "$PCI_ROOT/$audio/driver_override" 2>/dev/null || true)
    if [ -z "$drv" ] || [ "$drv" = "." ]; then
      ok "$audio 未绑定驱动"
    else
      info "$audio 绑定 $drv（compute-only 可选 unbind，见 O1.2；当前未启用）"
    fi
    [ -n "$ov" ] && [ "$ov" != "(null)" ] && dbg "driver_override=$ov"
  else
    info "无 audio 功能 ($audio)"
  fi
else
  info "跳过（GPU 不在）"
fi

# ------------------------------------------- 8. compute-only 校验
sect "8. compute-only（无 NVIDIA 显示/图形栈）"
if lsmod 2>/dev/null | grep -q '^nvidia_drm '; then
  fail "nvidia_drm 已加载（应由 install /bin/false 硬封，见 C29）"
else
  ok "nvidia_drm 未加载"
fi
if lsmod 2>/dev/null | grep -q '^nvidia_modeset '; then
  warn "nvidia_modeset 已加载（图形栈按需泄漏，见 C29）"
else
  ok "nvidia_modeset 未加载"
fi
if [ -n "$GPU" ] && [ -d "$PCI_ROOT/$GPU/drm" ]; then
  fail "GPU 存在 DRM 节点：$(ls "$PCI_ROOT/$GPU/drm" 2>/dev/null | tr '\n' ' ')"
else
  ok "GPU 无 DRM 节点（不参与显示）"
fi
gf=""
for f in /usr/share/vulkan/icd.d/nvidia_icd.json \
         /usr/share/vulkan/implicit_layer.d/nvidia_layers.json \
         /usr/share/vulkansc/icd.d/nvidia_icd_vksc.json \
         /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
         /etc/OpenCL/vendors/nvidia.icd; do
  [ -e "$f" ] && gf="$gf ${f##*/}"
done
if [ -z "$gf" ]; then
  ok "NVIDIA 图形入口文件已隐藏（INSTALL_MASK，见 C29）"
else
  warn "NVIDIA 图形入口文件仍存在:$gf（INSTALL_MASK 未生效？）"
fi
if grep -rsqE '^[[:space:]]*install[[:space:]]+nvidia_drm[[:space:]]+/bin/false' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null; then
  ok "nvidia_drm 已 install /bin/false 硬封"
else
  warn "modprobe.d 未见 install nvidia_drm /bin/false"
fi

# -------------------------------------------------------- 9. 内核日志 Xid
sect "9. 内核日志（近 24h Xid / fallen-off）"
lines=""; readable=0
if command -v journalctl >/dev/null 2>&1 && journalctl -k -b -n 1 >/dev/null 2>&1; then
  readable=1
  lines=$(journalctl -k -b --since "-24 hours" --no-pager 2>/dev/null | grep -iE 'Xid|fallen off')
elif [ "$(id -u)" = 0 ] && dmesg >/dev/null 2>&1; then
  readable=1
  lines=$(dmesg 2>/dev/null | grep -iE 'Xid|fallen off')
fi
if [ "$readable" != 1 ]; then
  warn "无法读取内核日志（需 root 或 systemd-journal 组）"
else
  n=$(printf '%s' "$lines" | grep -c .)
  if [ "$n" -eq 0 ]; then
    ok "无 Xid / fallen-off"
  else
    warn "有 $n 条（拔线瞬时的 Xid 79 属正常，请核对时间）"
    printf '%s\n' "$lines" | tail -3 | sed 's/^/        /'
  fi
fi

# ---------------------------------------------------------------- 结论
sect "结论"
printf '  %s%d OK%s, %s%d WARN%s, %s%d FAIL%s\n' \
  "$C_OK" "$OK_N" "$C_R" "$C_WARN" "$WARN_N" "$C_R" "$C_FAIL" "$FAIL_N" "$C_R"
if [ "$FAIL_N" -gt 0 ]; then
  printf '  %sDEGRADED%s\n' "$C_FAIL" "$C_R"; exit 2
elif [ "$WARN_N" -gt 0 ]; then
  printf '  %sHEALTHY（有告警）%s\n' "$C_WARN" "$C_R"; exit 1
else
  printf '  %sHEALTHY%s\n' "$C_OK" "$C_R"; exit 0
fi
