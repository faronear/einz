#!/usr/bin/env bash
# Einz Phase 0 端到端验收（任务 #13/#14/#15）
#
# 流程：pair_up（A 自举登记 + 口令托管 → 邀请码 → B 登记 + 凭口令接入，两端同一 Space Key）
#       → send(A) → sync(B 解密) → DB 明文隔离检查 → 白名单外拒绝
# 注：Multiverse 起白名单在服务端 DB（enroll 写入），旧的 config.json 白名单已废弃。
#
# 前置：server 已构建（npm run build 生成 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${EINZ_E2E_PORT:-3901}"
MESSAGE="秘密消息E2E-$(date +%s)"
SERVER_PID=""

# shellcheck source=./_e2e_lib.sh
. "$ROOT/cli/test/_e2e_lib.sh"

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

STORE_A="$WORK/store-a.json"
STORE_B="$WORK/store-b.json"

step "1. 两台设备准备（A 自举登记 + 口令托管 → 邀请码 → B 登记 + 凭口令接入）"
pair_up "$STORE_A" "$STORE_B"
echo "    A device_id=$(id_of store-a.json) person_id=$(field_of store-a.json person_id)"
echo "    B device_id=$(id_of store-b.json) person_id=$(field_of store-b.json person_id)"

step "2. A 发送消息"
dart run bin/einz.dart send --store "$STORE_A" --server "http://127.0.0.1:$PORT" --message "$MESSAGE"

step "3. B 增量同步并解密"
SYNC_OUT="$(dart run bin/einz.dart sync --store "$STORE_B" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_OUT"
assert_contains "$SYNC_OUT" "$MESSAGE" "B 成功解密出明文"

step "4. DB 明文隔离检查（Server 只应存密文）"
node -e "
const Database = require('$(wpath "$ROOT")/server/node_modules/better-sqlite3');
const db = new Database('$(wpath "$WORK")/einz.sqlite.db', { readonly: true });
const rows = db.prepare('SELECT ciphertext FROM messages').all();
if (rows.length === 0) { console.error('❌ 数据库无消息'); process.exit(1); }
const all = JSON.stringify(rows);
if (all.includes('$MESSAGE')) { console.error('❌ 数据库出现明文!'); process.exit(1); }
console.log('✅ 数据库 ' + rows.length + ' 条消息，全部为密文，无明文');
"

step "5. 白名单外设备应被拒绝"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/auth/challenge" \
  -H 'Content-Type: application/json' -d '{"device_id":"dev-evil"}')"
[ "$STATUS" = "403" ] && echo "✅ 白名单外设备返回 403" || { echo "❌ 期望 403 实际 $STATUS"; exit 1; }

echo ""
echo "🎉 Phase 0 端到端验收全部通过"
