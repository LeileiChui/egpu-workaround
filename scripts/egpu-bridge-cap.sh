#!/usr/bin/env bash
# egpu-bridge-cap.sh — 给 eGPU 的父桥（和 GPU 端点）设置
#   LnkCtl2: Target Link Speed = Gen${CAP_TARGET_SPEED}, bit5 = HASD
# 然后触发 retrain。必须在 nvidia.ko 绑定之前执行。
#
# 用法:
#   egpu-bridge-cap.sh apply     # 设置 cap（幂等）
#   egpu-bridge-cap.sh status    # 打印两端 LnkCtl2/LnkSta
#   egpu-bridge-cap.sh restore   # 清掉 bit5（保留 Target）
#   egpu-bridge-cap.sh detect    # 打印 GPU/父桥 BDF
#
# 需要 root（setpci 写 PCI 配置空间）。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${EGPU_CONF:-}"
if [ -z "$CONF" ]; then
  if [ -r /etc/egpu.conf ]; then CONF=/etc/egpu.conf; else CONF="$SELF_DIR/egpu.conf"; fi
fi
if [ ! -r "$CONF" ]; then
  printf 'egpu-bridge-cap: ERROR: config not readable: %s\n' "$CONF" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$CONF"

SETPCI="${SETPCI:-setpci}"
PCI_ROOT="${PCI_ROOT:-/sys/bus/pci/devices}"

LNKCTL2="CAP_EXP+0x30.W"   # Link Control 2
LNKCTL="CAP_EXP+0x10.W"    # Link Control
LNKSTA="CAP_EXP+0x12.W"    # Link Status
BIT5_HASD=0x20
BIT5_RETRAIN=0x20

die() { printf 'egpu-bridge-cap: ERROR: %s\n' "$*" >&2; exit 2; }
warn() { printf 'egpu-bridge-cap: %s\n' "$*" >&2; }

# 找唯一的 GPU BDF（vender:device 匹配）。多个时优先 BAR0 非 0。
find_gpu() {
  local d v dv best="" bestport=""
  for d in "$PCI_ROOT"/*; do
    [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
    v=$(<"$d/vendor"); dv=$(<"$d/device")
    [ "$v" = "0x$GPU_VID" ] && [ "$dv" = "0x$GPU_DID" ] || continue
    local bdf; bdf=$(basename "$(readlink -f "$d")")
    local r0; r0=$(awk 'NR==1{print $1}' "$d/resource" 2>/dev/null)
    if [ -n "$r0" ] && [ "$r0" != "0x0000000000000000" ] && [ "$r0" != "0x0" ]; then
      best="$bdf"; break
    fi
    [ -z "$best" ] && best="$bdf"
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

find_parent() { # $1 = gpu bdf
  local real; real=$(readlink -f "$PCI_ROOT/$1") || return 1
  basename "$(dirname "$real")"
}

read_w() { "$SETPCI" -s "$1" "$2" 2>/dev/null; }
write_w() { "$SETPCI" -s "$1" "$2=$3" >/dev/null 2>&1; }

cap_apply() {
  local gpu bridge cur new lc
  gpu=$(find_gpu) || die "GPU ${GPU_VID}:${GPU_DID} 未找到"
  bridge=$(find_parent "$gpu") || die "无法定位父桥"

  # --- 父桥 ---
  cur=$(read_w "$bridge" "$LNKCTL2") || die "读不到父桥 LnkCtl2"
  new=$(( (0x$cur & ~0xF) | (CAP_TARGET_SPEED & 0xF) ))
  [ "$CAP_SET_HASD" = "1" ] && new=$(( new | BIT5_HASD ))
  new=$(printf '%04x' "$new")
  if [ "$cur" = "$new" ]; then
    printf 'bridge=%s LnkCtl2 already 0x%s (Target=Gen%s HASD=%s)\n' \
      "$bridge" "$cur" "$CAP_TARGET_SPEED" "$CAP_SET_HASD"
  else
    write_w "$bridge" "$LNKCTL2" "$new" || die "写父桥 LnkCtl2 失败"
    printf 'bridge=%s LnkCtl2 0x%s -> 0x%s\n' "$bridge" "$cur" "$new"
    lc=$(read_w "$bridge" "$LNKCTL"); lc=$((0x$lc)); lc=$(printf '%04x' $(( lc | BIT5_RETRAIN )))
    write_w "$bridge" "$LNKCTL" "$lc" || die "触发 retrain 失败"
    printf 'bridge=%s retrain triggered\n' "$bridge"
  fi

  # --- GPU 端点（HASD，防端点侧自主升速）---
  cur=$(read_w "$gpu" "$LNKCTL2") || { warn "读不到 GPU LnkCtl2（跳过端点 cap）"; return 0; }
  new=$(( (0x$cur & ~0xF) | (CAP_TARGET_SPEED & 0xF) ))
  [ "$CAP_SET_HASD" = "1" ] && new=$(( new | BIT5_HASD ))
  new=$(printf '%04x' "$new")
  if [ "$cur" = "$new" ]; then
    printf 'gpu=%s LnkCtl2 already 0x%s\n' "$gpu" "$cur"
  else
    write_w "$gpu" "$LNKCTL2" "$new" && printf 'gpu=%s LnkCtl2 0x%s -> 0x%s\n' "$gpu" "$cur" "$new" \
      || warn "写 GPU LnkCtl2 失败（跳过）"
  fi
  return 0
}

cap_status() {
  local gpu bridge v2 st
  gpu=$(find_gpu) || die "GPU ${GPU_VID}:${GPU_DID} 未找到"
  bridge=$(find_parent "$gpu") || die "无法定位父桥"
  printf 'gpu=%s  parent=%s\n' "$gpu" "$bridge"
  for dev in "$bridge" "$gpu"; do
    v2=$(read_w "$dev" "$LNKCTL2"); st=$(read_w "$dev" "$LNKSTA")
    if [ -z "$v2" ]; then printf '  %-14s <unreadable>\n' "$dev"; continue; fi
    local i=$((0x$v2)); local s=$((0x$st))
    printf '  %-14s LnkCtl2=0x%04x target=Gen%d hasd=%d | LnkSta speed=Gen%d width=x%d\n' \
      "$dev" "$i" $(( i & 0xF )) $(( (i>>5)&1 )) $(( s & 0xF )) $(( (s>>4)&0x3F ))
  done
}

cap_restore() {
  local gpu bridge cur new
  gpu=$(find_gpu) || die "GPU ${GPU_VID}:${GPU_DID} 未找到"
  bridge=$(find_parent "$gpu") || die "无法定位父桥"
  for dev in "$bridge" "$gpu"; do
    cur=$(read_w "$dev" "$LNKCTL2") || continue
    new=$(printf '%04x' $(( 0x$cur & ~BIT5_HASD )))
    if [ "$cur" = "$new" ]; then printf '  %s bit5 已是 0\n' "$dev"
    else write_w "$dev" "$LNKCTL2" "$new" && printf '  %s LnkCtl2 0x%s -> 0x%s (bit5 清除)\n' "$dev" "$cur" "$new"; fi
  done
}

case "${1:-}" in
  apply)   cap_apply ;;
  status)  cap_status ;;
  restore) cap_restore ;;
  detect)  printf 'gpu=%s\nparent=%s\n' "$(find_gpu)" "$(find_parent "$(find_gpu)")" ;;
  *) printf 'usage: %s {apply|status|restore|detect}\n' "${0##*/}" >&2; exit 1 ;;
esac
