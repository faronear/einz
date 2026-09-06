#!/usr/bin/env bash
# 自动补拉断线场景验证（2026-09-02）：A(TUI 常驻) 断线期间 B 发消息，
# 断言无需手动 /sync，A 在重连后通过自动补拉收到（FOUND-VIA-AUTOSYNC）。
# 前置：demo 环境已登记（enroll A/B 并 auth）一次。
# 注意：不能跑 setup.sh（其 import 会把 store-b.space_id 重置为 space-demo，
# 与 enroll 写入的真实 space_id 不一致 → AAD 解密失败）。
# 用法： cd cli && bash test/auto_sync_check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SERVER="http://127.0.0.1:3901"
PROBE_OUT=/tmp/einz_autosync_probe.log

# 对齐双端 space_id（幂等）：以 store-a 为准写入 store-b（同一把 Space Key，
# 但旧 import 流程把 B 写成了 space-demo → AAD 不匹配，必须统一）
python3 - <<'EOF'
import json
a = json.load(open('demo/store-a.json'))
b = json.load(open('demo/store-b.json'))
b['space_id'] = a['space_id']
json.dump(b, open('demo/store-b.json', 'w'), ensure_ascii=False, indent=2)
print('aligned space_id =', a['space_id'])
EOF

ensure_server() {
  if ! curl -s -o /dev/null --max-time 1 "$SERVER/devices" 2>/dev/null; then
    (cd "$ROOT/../server" && EINZ_DB="$ROOT/demo/einz.sqlite.db" \
      EINZ_FILES="$ROOT/demo/files" \
      PORT=3901 nohup node dist/app.js >"$ROOT/demo/server.log" 2>&1 & echo $! > "$ROOT/demo/server.pid")
    for i in $(seq 1 40); do curl -s -o /dev/null "$SERVER/devices" && break; sleep 0.3; done
  fi
}

ensure_server

# B 预先认证一次（避免每次尝试里 auth 的 dart 启动耗时挤占断线窗口）
dart run bin/einz.dart auth --store demo/store-b.json --server "$SERVER" >/dev/null 2>&1

for attempt in $(seq 1 "${MAX_ATTEMPTS:-3}"); do
  TARGET="gap-check-$attempt-$(date +%s)"
  rm -f "$PROBE_OUT"
  # 2) 启动探测进程（A：auth + startWs 常驻）
  dart run test/auto_sync_probe.dart "$TARGET" 55 >"$PROBE_OUT" 2>&1 &
  PROBE_PID=$!
  for i in $(seq 1 100); do grep -q READY_WAITING "$PROBE_OUT" 2>/dev/null && break; sleep 0.5; done
  if ! grep -q READY_WAITING "$PROBE_OUT"; then
    echo "❌ 探测未就绪（auth/WS 失败）"; cat "$PROBE_OUT"; kill "$PROBE_PID" 2>/dev/null; exit 1
  fi
  sleep 1 # 让 WS 稳定 connected

  # 3) 杀 server → A 的 WS 掉线（reconnecting，退避重试 ~1s/3s/7s/15s/30s）。
  #    用 pkill（不依赖 server.pid——该文件可能缺失导致 stop.sh 空转）；
  #    停 8s：A 的 +1/+3/+7s 重试全部失败，下一次在 +15s——B 的消息必然落在缺口内
  pkill -f "dist/app.js" 2>/dev/null || true
  rm -f "$ROOT/demo/server.pid"
  sleep 8

  # 4) 重启 server 并等就绪（~+8.5s 起，落在 A 的 +7s 与 +15s 重试之间）
  ensure_server

  # 5) B 立即发目标消息（A 仍在退避重连 → 断线期间漏掉 → 需自动补拉）
  dart run bin/einz.dart send --store demo/store-b.json --server "$SERVER" --message "$TARGET" >/dev/null 2>&1

  # 6) 等待探测结果：检测到 FOUND 立即处理退出（避免进程回收类挂起）
  for i in $(seq 1 130); do
    if grep -q 'FOUND-VIA-AUTOSYNC' "$PROBE_OUT"; then
      echo "🎉 验证通过（attempt=$attempt）：断线后自动补拉送达，无需 /sync"
      cat "$PROBE_OUT"
      exit 0
    fi
    grep -qE 'FOUND-VIA-(PUSH|POLL)' "$PROBE_OUT" && break
    grep -q 'TIMEOUT' "$PROBE_OUT" && break
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$PROBE_PID" 2>/dev/null || true

  if grep -q 'FOUND-VIA-AUTOSYNC' "$PROBE_OUT"; then
    echo "🎉 验证通过（attempt=$attempt）：断线后自动补拉送达，无需 /sync"
    cat "$PROBE_OUT"
    exit 0
  fi
  echo "attempt=$attempt 未命中 autosync 路径：$(grep -E 'STATUS|AUTOSYNC|FOUND|TIMEOUT' "$PROBE_OUT" | tr '\n' ' ')"
done

echo "❌ 3 次尝试均未验证 autosync 送达"; cat "$PROBE_OUT"; exit 1
