#!/usr/bin/env bash
# OnlySpace Phase 0 端到端验收（任务 #13/#14/#15）
#
# 流程：CLI init(A/B) → config(A 生成 Space Key + 密封 + 白名单) → import(B)
#       → 启动 Server → auth(双端) → send(A) → sync(B 解密) → DB 明文隔离检查
#
# 前置：server 已构建（npm run build 生成 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${ONLYSPACE_E2E_PORT:-3901}"
MESSAGE="秘密消息E2E-$(date +%s)"
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

echo "==> 1. CLI init 两台设备"
cd "$ROOT/cli"
dart run bin/onlyspace.dart init --store "$WORK/store-a.json" --device-id dev-a1
dart run bin/onlyspace.dart init --store "$WORK/store-b.json" --device-id dev-b1
PUB_A="$(dart run bin/onlyspace.dart pubkey --store "$WORK/store-a.json")"
PUB_B="$(dart run bin/onlyspace.dart pubkey --store "$WORK/store-b.json")"
echo "    A=$PUB_A"
echo "    B=$PUB_B"

echo "==> 2. config（A 生成 Space Key，密封双方，产出服务器 config.json）"
dart run bin/onlyspace.dart config \
  --store "$WORK/store-a.json" \
  --peer-pubkey "$PUB_B" \
  --space-id "space-e2e" \
  --out-config "$WORK/config.json" \
  --out-sealed-peer "$WORK/sealed-b.txt"

echo "==> 3. import（B 导入密封 Space Key 并解封）"
dart run bin/onlyspace.dart import \
  --store "$WORK/store-b.json" \
  --sealed-file "$WORK/sealed-b.txt" \
  --space-id "space-e2e"

echo "==> 4. 启动 Server（临时白名单 $WORK/config.json）"
(cd "$ROOT/server" && ONLYSPACE_CONFIG="$WORK/config.json" \
  ONLYSPACE_DB="$WORK/app.db" \
  ONLYSPACE_FILES="$WORK/files" \
  PORT="$PORT" node dist/app.js >"$WORK/server.log" 2>&1) &
SERVER_PID=$!
sleep 1
for i in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/devices" && break
  sleep 0.3
done

echo "==> 5. 双端认证（challenge-response）"
dart run bin/onlyspace.dart auth --store "$WORK/store-a.json" --server "http://127.0.0.1:$PORT"
dart run bin/onlyspace.dart auth --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT"

echo "==> 6. A 发送消息"
dart run bin/onlyspace.dart send --store "$WORK/store-a.json" --server "http://127.0.0.1:$PORT" --message "$MESSAGE"

echo "==> 7. B 增量同步并解密"
SYNC_OUT="$(dart run bin/onlyspace.dart sync --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_OUT"
echo "$SYNC_OUT" | grep -q "$MESSAGE" \
  && echo "✅ B 成功解密出明文" \
  || { echo "❌ B 未解密出明文"; exit 1; }

echo "==> 8. DB 明文隔离检查（Server 只应存密文）"
# 跨平台：Windows（Git Bash）用 cygpath 转 MSYS 路径；macOS/Linux 直接用原路径
if command -v cygpath >/dev/null 2>&1; then
  ROOT_WIN="$(cygpath -m "$ROOT")"
  WORK_WIN="$(cygpath -m "$WORK")"
else
  ROOT_WIN="$ROOT"
  WORK_WIN="$WORK"
fi
node -e "
const Database = require('$ROOT_WIN/server/node_modules/better-sqlite3');
const db = new Database('$WORK_WIN/app.db', { readonly: true });
const rows = db.prepare('SELECT ciphertext FROM messages').all();
if (rows.length === 0) { console.error('❌ 数据库无消息'); process.exit(1); }
const all = JSON.stringify(rows);
if (all.includes('$MESSAGE')) { console.error('❌ 数据库出现明文!'); process.exit(1); }
console.log('✅ 数据库 ' + rows.length + ' 条消息，全部为密文，无明文');
"
echo "==> 9. 白名单外设备应被拒绝"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/auth/challenge \
  -H 'Content-Type: application/json' -d '{"device_id":"dev-evil"}')"
[ "$STATUS" = "403" ] && echo "✅ 白名单外设备返回 403" || { echo "❌ 期望 403 实际 $STATUS"; exit 1; }

echo ""
echo "🎉 Phase 0 端到端验收全部通过"
