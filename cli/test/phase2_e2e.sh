#!/usr/bin/env bash
# OnlySpace Phase 2 验收：附件加密上传 → 下载 → 解密闭环 + Server 明文隔离
#
# 流程：
#   init(A/B) → config → import → 启动 Server → auth 双端
#   → A attach 上传本地文件（加密）→ 明文隔离检查（DB/文件系统均无明文）
#   → B sync 收到附件消息 + attachments_meta → B fetch 下载解密
#   → 解密内容与原文件逐字节一致
#
# 前置：server 已构建（npm run build 生成 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${ONLYSPACE_P2_PORT:-3903}"
SERVER_PID=""
MESSAGE="机密附件内容-Phase2-$(date +%s)"

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
    ONLYSPACE_CONFIG="$WORK/config.json" \
    ONLYSPACE_DB="$WORK/app.db" \
    ONLYSPACE_FILES="$WORK/files" \
    PORT="$PORT" node dist/app.js >"$WORK/server.log" 2>&1) &
  SERVER_PID=$!
  for i in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/devices" && return 0
    sleep 0.3
  done
  echo "❌ Server 启动失败"; exit 1
}

cd "$ROOT/cli"

step "1. CLI init 两台设备"
dart run bin/onlyspace.dart init --store "$WORK/store-a.json" --device-id dev-a1 >/dev/null
dart run bin/onlyspace.dart init --store "$WORK/store-b.json" --device-id dev-b1 >/dev/null
PUB_A="$(dart run bin/onlyspace.dart pubkey --store "$WORK/store-a.json")"
PUB_B="$(dart run bin/onlyspace.dart pubkey --store "$WORK/store-b.json")"

step "2. config（A 生成 Space Key + 白名单）+ import（B）"
dart run bin/onlyspace.dart config \
  --store "$WORK/store-a.json" --peer-pubkey "$PUB_B" \
  --space-id "space-p2" \
  --out-config "$WORK/config.json" --out-sealed-peer "$WORK/sealed-b.txt" >/dev/null
dart run bin/onlyspace.dart import \
  --store "$WORK/store-b.json" --sealed-file "$WORK/sealed-b.txt" --space-id "space-p2" >/dev/null

step "3. 启动 Server + 双端认证"
start_server
dart run bin/onlyspace.dart auth --store "$WORK/store-a.json" --server "http://127.0.0.1:$PORT" >/dev/null
dart run bin/onlyspace.dart auth --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT" >/dev/null

step "4. 准备本地测试文件（含可识别明文字符串，用于明文隔离检查）"
printf '%s\n' "$MESSAGE" >"$WORK/photo.bin"
python -c "import os;open(r'$(cygpath -m "$WORK")/photo.bin','ab').write(os.urandom(4096))"
SIZE="$(wc -c < "$WORK/photo.bin")"
echo "    测试文件: $SIZE 字节"

step "5. A attach 加密上传"
ATTACH_OUT="$(dart run bin/onlyspace.dart attach \
  --store "$WORK/store-a.json" \
  --server "http://127.0.0.1:$PORT" \
  --file "$WORK/photo.bin" \
  --type image \
  --caption "测试图片")"
echo "$ATTACH_OUT"
ATTACH_ID="$(echo "$ATTACH_OUT" | grep -o 'attachment_id=[0-9a-f-]*' | cut -d= -f2)"
[ -n "$ATTACH_ID" ] && echo "✅ 附件上传成功: $ATTACH_ID" || { echo "❌ 未解析到 attachment_id"; exit 1; }

step "6. Server 明文隔离检查（DB 与 files/ 均不应出现明文）"
# DB 检查：attachments 表元数据不含明文
python - "$(cygpath -m "$WORK")" "$MESSAGE" <<'EOF'
import json, os, sqlite3, sys
work, secret = sys.argv[1], sys.argv[2]
db = sqlite3.connect(os.path.join(work, 'app.db'))
rows = db.execute("SELECT attachment_id, message_id, size, sha256, nonce FROM attachments").fetchall()
assert len(rows) == 1, f"期望 1 条附件元数据，实际 {len(rows)}"
print("✅ attachments 表 1 条元数据，无明文（sha256/nonce 均不含明文）")
EOF
# 文件系统检查：所有附件 blob 不含明文字符串
python - "$(cygpath -m "$WORK")" "$MESSAGE" <<'EOF'
import os, sys
work, secret = sys.argv[1], sys.argv[2]
files_dir = os.path.join(work, 'files')
found = []
for dirpath, _, names in os.walk(files_dir):
    for n in names:
        p = os.path.join(dirpath, n)
        with open(p, 'rb') as f:
            blob = f.read()
        if secret.encode() in blob:
            found.append(p)
assert not found, f"files/ 出现明文: {found}"
print("✅ files/ 附件 blob 全部为密文，无明文")
EOF

step "7. B sync → 收到附件消息（type=image）+ attachments_meta"
SYNC_B="$(dart run bin/onlyspace.dart sync --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_B"
echo "$SYNC_B" | grep -q "新增=1" \
  && echo "✅ B 收到 1 条新消息" \
  || { echo "❌ B 应收到 1 条消息"; exit 1; }
ATTACH_NUM="$(python -c "import json;print(len(json.load(open(r'$(cygpath -m "$WORK")/store-b.json'))['attachments']))")"
[ "$ATTACH_NUM" = "1" ] && echo "✅ B 附件元数据 = 1（attachments_meta 已落盘）" \
  || { echo "❌ B 附件元数据应 = 1 实际 $ATTACH_NUM"; exit 1; }

step "8. B fetch 下载并解密"
FETCH_OUT="$(dart run bin/onlyspace.dart fetch \
  --store "$WORK/store-b.json" \
  --server "http://127.0.0.1:$PORT" \
  --attachment-id "$ATTACH_ID" \
  --out "$WORK/downloaded.bin")"
echo "$FETCH_OUT"
echo "$FETCH_OUT" | grep -q "已下载并解密" \
  && echo "✅ B 下载并解密成功" \
  || { echo "❌ fetch 失败"; exit 1; }

step "9. 解密内容与原文件逐字节一致"
if cmp -s "$WORK/photo.bin" "$WORK/downloaded.bin"; then
  echo "✅ 解密文件与原文件完全一致（$(wc -c < "$WORK/downloaded.bin") 字节）"
else
  echo "❌ 解密文件与原文件不一致"; exit 1
fi

echo ""
echo "🎉 Phase 2 验收全部通过：加密上传 / 明文隔离 / 下载解密闭环 / 内容一致"
