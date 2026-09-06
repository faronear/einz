#!/usr/bin/env bash
# Einz Phase 1 验收：离线发送 → 恢复网络 → 自动补发 → 无重复无乱序
#
# 流程：
#   init(A/B) → config(A 生成 Space Key) → import(B) → 启动 Server → auth 双端
#   → 停 Server（模拟离线）→ A 离线发 3 条（全部入队）
#   → 重启 Server（模拟恢复）→ A sync 自动补发（队列清空）
#   → B sync 收到全部 3 条（无重复、seq 升序无乱序）
#   → 幂等验证：B 再 sync 新增=0
#
# 前置：server 已构建（npm run build 生成 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${EINZ_P1_PORT:-3902}"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # Windows（Git Bash）下 server 进程退出是异步的，句柄未释放时 rm 会报 EBUSY，重试几次
  for _ in 1 2 3 4 5; do
    rm -rf "$WORK" 2>/dev/null && break
    sleep 0.3
  done
}
trap cleanup EXIT

step() { echo "==> $1"; }

start_server() {
  # 用 exec 替换 subshell 为 node，使 $! 直接是 node 进程（Git Bash 下 kill subshell 杀不掉子进程）
  (cd "$ROOT/server" && exec env \
    EINZ_CONFIG="$WORK/config.json" \
    EINZ_DB="$WORK/einz.sqlite.db" \
    EINZ_FILES="$WORK/files" \
    PORT="$PORT" node dist/app.js >"$WORK/server.log" 2>&1) &
  SERVER_PID=$!
  for i in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/devices" && return 0
    sleep 0.3
  done
  echo "❌ Server 启动失败"; exit 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # 等端口释放，避免重启时端口占用
  for i in $(seq 1 30); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/devices" 2>/dev/null && sleep 0.3 || { SERVER_PID=""; return 0; }
  done
  echo "⚠️ Server 未及时退出，继续"
  SERVER_PID=""
}

cd "$ROOT/cli"

step "1. CLI init 两台设备"
dart run bin/einz.dart init --store "$WORK/store-a.json" --device-id dev-a1 >/dev/null
dart run bin/einz.dart init --store "$WORK/store-b.json" --device-id dev-b1 >/dev/null
PUB_A="$(dart run bin/einz.dart pubkey --store "$WORK/store-a.json")"
PUB_B="$(dart run bin/einz.dart pubkey --store "$WORK/store-b.json")"

step "2. config（A 生成 Space Key + 白名单）+ import（B）"
dart run bin/einz.dart config \
  --store "$WORK/store-a.json" --peer-pubkey "$PUB_B" \
  --space-id "space-p1" \
  --out-config "$WORK/config.json" --out-envelope-peer "$WORK/envelope-b.txt" >/dev/null
dart run bin/einz.dart import \
  --store "$WORK/store-b.json" --envelope-file "$WORK/envelope-b.txt" --space-id "space-p1" >/dev/null

step "3. 启动 Server + 双端认证"
start_server
dart run bin/einz.dart auth --store "$WORK/store-a.json" --server "http://127.0.0.1:$PORT" >/dev/null
dart run bin/einz.dart auth --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT" >/dev/null

step "4. 停 Server（模拟离线）→ A 离线发送 3 条"
stop_server
for i in 1 2 3; do
  OUT="$(dart run bin/einz.dart send --store "$WORK/store-a.json" \
    --server "http://127.0.0.1:$PORT" --message "离线消息$i")"
  echo "$OUT" | grep -q "已留在队列" \
    && echo "    ✅ 消息$i 发送失败并留队" \
    || { echo "❌ 消息$i 应留在队列"; echo "$OUT"; exit 1; }
done
PENDING="$(python -c "import json;print(len(json.load(open(r'$(cygpath -m "$WORK")/store-a.json'))['pending']))")"
[ "$PENDING" = "3" ] && echo "✅ 离线队列 = 3" || { echo "❌ 期望队列 3 实际 $PENDING"; exit 1; }

step "5. 重启 Server（模拟恢复）→ A sync 自动补发"
start_server
SYNC_A="$(dart run bin/einz.dart sync --store "$WORK/store-a.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_A"
echo "$SYNC_A" | grep -q "补发=3" \
  && echo "✅ A 自动补发 3 条成功" \
  || { echo "❌ A 应补发 3 条"; exit 1; }
echo "$SYNC_A" | grep -q "队列剩余=0" \
  && echo "✅ A 离线队列已清空" \
  || { echo "❌ A 队列应清空"; exit 1; }

step "6. B sync → 收到全部 3 条，无重复无乱序"
SYNC_B="$(dart run bin/einz.dart sync --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_B"
# 每条消息恰好出现一次（无重复）
for i in 1 2 3; do
  N="$(echo "$SYNC_B" | grep -c "离线消息$i")"
  [ "$N" = "1" ] && echo "    ✅ 离线消息$i 恰好 1 条" || { echo "❌ 离线消息$i 出现 $N 次"; exit 1; }
done
# seq 升序（无乱序）：1 2 3 的行号递增
L1="$(echo "$SYNC_B" | grep -n "seq=1\]" | head -1 | cut -d: -f1)"
L2="$(echo "$SYNC_B" | grep -n "seq=2\]" | head -1 | cut -d: -f1)"
L3="$(echo "$SYNC_B" | grep -n "seq=3\]" | head -1 | cut -d: -f1)"
if [ -n "$L1" ] && [ -n "$L2" ] && [ -n "$L3" ] && [ "$L1" -lt "$L2" ] && [ "$L2" -lt "$L3" ]; then
  echo "✅ 消息顺序无乱序（seq=1 < seq=2 < seq=3）"
else
  echo "❌ 消息乱序: $L1 $L2 $L3"; exit 1
fi

step "7. 幂等验证：B 再次 sync → 新增=0"
SYNC_B2="$(dart run bin/einz.dart sync --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_B2" | grep -q "新增=0" \
  && echo "✅ 重复同步无重复消息（锚点不倒退）" \
  || { echo "❌ 二次同步应有新增=0"; exit 1; }

step "8. WS 实时：B listen 收到 A 新消息（5 秒窗口）"
LISTEN_OUT="$WORK/listen-b.log"
( dart run bin/einz.dart listen --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT" >"$LISTEN_OUT" 2>&1 &
  LISTEN_PID=$!
  sleep 2
  dart run bin/einz.dart send --store "$WORK/store-a.json" \
    --server "http://127.0.0.1:$PORT" --message "实时消息" >/dev/null
  sleep 3
  kill "$LISTEN_PID" 2>/dev/null || true
  wait "$LISTEN_PID" 2>/dev/null || true
)
grep -q "实时消息" "$LISTEN_OUT" \
  && echo "✅ B 通过 WS 实时收到消息" \
  || { echo "❌ B 未实时收到"; cat "$LISTEN_OUT"; exit 1; }

echo ""
echo "🎉 Phase 1 验收全部通过：离线发送 / 自动补发 / 无重复 / 无乱序 / WS 实时"
