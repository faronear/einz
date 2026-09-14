#!/usr/bin/env bash
# 自动补拉断线场景验证（2026-09-02；2026-09-14 改为自包含）：
# A（TUI 常驻的同一代码路径 ChatSession.startWs）断线期间 B 发消息，
# 断言无需手动 /sync，A 在重连后通过**自动补拉**收到（FOUND-VIA-AUTOSYNC）。
#
# 自包含：不再依赖本机 cli/demo/ 环境（那是 git-ignored 的手工目录）与硬编码端口——
# 脚本自己 pair_up 一套临时两设备环境，跑完即清理。
# 用法： cd cli && bash test/auto_sync_check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${EINZ_AUTOSYNC_PORT:-3911}"
SERVER_PID=""
PROBE_PID=""
PROBE_OUT="$WORK/probe.log"

# shellcheck source=./_e2e_lib.sh
. "$ROOT/cli/test/_e2e_lib.sh"

cleanup() {
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    rm -rf "$WORK" 2>/dev/null && break
    sleep 0.3
  done
}
trap cleanup EXIT

step() { echo "==> $1"; }
SERVER="http://127.0.0.1:$PORT"
STORE_A="$WORK/store-a.json"
STORE_B="$WORK/store-b.json"

step "1. 两台设备准备（A 自举登记 + 口令托管 → 邀请码 → B 登记 + 凭口令接入）"
pair_up "$STORE_A" "$STORE_B"

for attempt in $(seq 1 "${MAX_ATTEMPTS:-3}"); do
  TARGET="gap-check-${attempt}-$(date +%s)"
  rm -f "$PROBE_OUT"

  step "attempt=${attempt}: 启动探测进程（A：auth + startWs 常驻）"
  dart run test/auto_sync_probe.dart "$TARGET" 55 "$STORE_A" "$SERVER" >"$PROBE_OUT" 2>&1 &
  PROBE_PID=$!
  for _ in $(seq 1 100); do grep -q READY_WAITING "$PROBE_OUT" 2>/dev/null && break; sleep 0.5; done
  if ! grep -q READY_WAITING "$PROBE_OUT"; then
    echo "❌ 探测未就绪（auth/WS 失败）"; cat "$PROBE_OUT"; exit 1
  fi
  sleep 1 # 让 WS 稳定 connected

  # 杀 server → A 的 WS 掉线（reconnecting，退避重试 ~1s/3s/7s/15s/30s）。
  # 停 8s：A 的 +1/+3/+7s 重试全部失败，下一次在 +15s——B 的消息必然落在缺口内
  step "attempt=${attempt}: 停 Server 8s（制造 A 的断线缺口）"
  stop_server
  sleep 8

  step "attempt=${attempt}: 重启 Server → B 立即发目标消息（A 仍在退避重连）"
  start_server
  dart run bin/einz.dart send --store "$STORE_B" --server "$SERVER" --message "$TARGET" >/dev/null 2>&1

  # 等探测结果：命中 FOUND 立即退出（避免进程回收类挂起）
  for _ in $(seq 1 130); do
    if grep -q 'FOUND-VIA-AUTOSYNC' "$PROBE_OUT"; then
      echo "🎉 验证通过（attempt=${attempt}）：断线后自动补拉送达，无需 /sync"
      cat "$PROBE_OUT"
      exit 0
    fi
    grep -qE 'FOUND-VIA-(PUSH|POLL)' "$PROBE_OUT" && break
    grep -q 'TIMEOUT' "$PROBE_OUT" && break
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$PROBE_PID" 2>/dev/null || true
  PROBE_PID=""

  if grep -q 'FOUND-VIA-AUTOSYNC' "$PROBE_OUT"; then
    echo "🎉 验证通过（attempt=${attempt}）：断线后自动补拉送达，无需 /sync"
    cat "$PROBE_OUT"
    exit 0
  fi
  echo "attempt=${attempt} 未命中 autosync 路径：$(grep -E 'STATUS|AUTOSYNC|FOUND|TIMEOUT' "$PROBE_OUT" | tr '\n' ' ')"
done

echo "❌ 3 次尝试均未验证 autosync 送达"; cat "$PROBE_OUT"; exit 1
