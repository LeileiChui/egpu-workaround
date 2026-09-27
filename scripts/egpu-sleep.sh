#!/usr/bin/env bash
# egpu-sleep.sh — systemd sleep hook（安装为 /usr/lib/systemd/system-sleep/50-egpu）
#
# 背景（T12/C19/C21 实测）：
#   s2idle 挂起时 eGPU 会掉出总线（Xid 79），恢复后 GSP 起不来（Xid 143/154），
#   驱动进入坏状态 → 之后 `modprobe -r` 无法干净完成（refcount -1），
#   再 remove TB 交换机就会卡死（D 状态，只能重启）。
#   对策：**挂起前先卸载 nvidia**，恢复后再 bring-up。
#
# systemd-sleep 调用约定：$1 = pre|post ，$2 = suspend|hibernate|...
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="${LOG_TAG:-egpu}"
log() { printf '[egpu-sleep] %s\n' "$*" >&2; command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" "sleep $*"; }

phase="${1:-}"
what="${2:-}"

# 优先用 PATH 里已安装的脚本，退回脚本同目录
DOWN="$(command -v egpu-down.sh 2>/dev/null || echo "$SELF_DIR/egpu-down.sh")"
UP="$(command -v egpu-up.sh 2>/dev/null || echo "$SELF_DIR/egpu-up.sh")"

# 只对挂起/休眠感兴趣；也只在 eGPU 相关时才动
case "$phase" in
  pre)
    log "pre-$what: 卸载 nvidia（避免 s2idle 后坏状态）"
    # 同步执行且要有超时——绝不能因为它把挂起卡住
    timeout 60 "$DOWN" || log "pre 卸载未成功（继续挂起）"
    ;;
  post)
    log "post-$what: 后台 bring-up eGPU"
    # 异步，避免阻塞恢复；用 systemd-run 脱离 sleep 钩子的生命周期
    if command -v systemd-run >/dev/null 2>&1; then
      systemd-run --collect --unit=egpu-resume-bringup \
        --description="eGPU resume bring-up" \
        "$UP" >/dev/null 2>&1 \
        || (setsid "$UP" >/dev/null 2>&1 &)
    else
      setsid "$UP" >/dev/null 2>&1 &
    fi
    ;;
  *)
    log "unknown phase '$phase' (expect pre|post)"
    exit 1
    ;;
esac
exit 0
