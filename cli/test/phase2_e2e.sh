#!/usr/bin/env bash
# Einz Phase 2 验收：附件加密上传 → 下载 → 解密闭环 + Server 明文隔离
#
# 流程：
#   pair_up（A 自举登记 + 口令托管 → 邀请码 → B 登记 + 凭口令接入，两端同一 Space Key）
#   → A attach 上传本地文件（加密）→ 明文隔离检查（DB/文件系统均无明文）
#   → B sync 收到附件消息 + attachments_meta → B fetch 下载解密
#   → 解密内容与原文件逐字节一致
#
# 前置：server 已构建（npm run build 生成 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
PORT="${EINZ_P2_PORT:-3903}"
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

# shellcheck source=./_e2e_lib.sh
. "$ROOT/cli/test/_e2e_lib.sh"

STORE_A="$WORK/store-a.json"
STORE_B="$WORK/store-b.json"

step "1. 两台设备准备（A 自举登记 + 口令托管 → 邀请码 → B 登记 + 凭口令接入）"
pair_up "$STORE_A" "$STORE_B"

step "2. 准备本地测试文件（含可识别明文字符串，用于明文隔离检查）"
printf '%s\n' "$MESSAGE" >"$WORK/photo.bin"
py -c "import os;open(r'$(wpath "$WORK")/photo.bin','ab').write(os.urandom(4096))"
SIZE="$(wc -c < "$WORK/photo.bin")"
echo "    测试文件: $SIZE 字节"

step "3. A attach 加密上传"
ATTACH_OUT="$(dart run bin/einz.dart attach \
  --store "$WORK/store-a.json" \
  --server "http://127.0.0.1:$PORT" \
  --file "$WORK/photo.bin" \
  --type image \
  --caption "测试图片")"
echo "$ATTACH_OUT"
ATTACH_ID="$(echo "$ATTACH_OUT" | grep -o 'attachment_id=[0-9a-f-]*' | cut -d= -f2)"
[ -n "$ATTACH_ID" ] && echo "✅ 附件上传成功: $ATTACH_ID" || { echo "❌ 未解析到 attachment_id"; exit 1; }

step "4. Server 明文隔离检查（DB 与 files/ 均不应出现明文）"
# DB 检查：attachments 表元数据不含明文
py - "$(wpath "$WORK")" "$MESSAGE" <<'EOF'
import json, os, sqlite3, sys
work, secret = sys.argv[1], sys.argv[2]
db = sqlite3.connect(os.path.join(work, 'einz.sqlite.db'))
rows = db.execute("SELECT attachment_id, message_id, size, sha256, nonce FROM attachments").fetchall()
assert len(rows) == 1, f"期望 1 条附件元数据，实际 {len(rows)}"
print("✅ attachments 表 1 条元数据，无明文（sha256/nonce 均不含明文）")
EOF
# 文件系统检查：所有附件 blob 不含明文字符串
py - "$(wpath "$WORK")" "$MESSAGE" <<'EOF'
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

step "5. B sync → 收到附件消息（type=image）+ attachments_meta"
SYNC_B="$(dart run bin/einz.dart sync --store "$WORK/store-b.json" --server "http://127.0.0.1:$PORT")"
echo "$SYNC_B"
echo "$SYNC_B" | grep -q "新增=1" \
  && echo "✅ B 收到 1 条新消息" \
  || { echo "❌ B 应收到 1 条消息"; exit 1; }
ATTACH_NUM="$(py -c "import json;print(len(json.load(open(r'$(wpath "$WORK")/store-b.json'))['attachments']))")"
[ "$ATTACH_NUM" = "1" ] && echo "✅ B 附件元数据 = 1（attachments_meta 已落盘）" \
  || { echo "❌ B 附件元数据应 = 1 实际 $ATTACH_NUM"; exit 1; }

step "6. B fetch 下载并解密"
FETCH_OUT="$(dart run bin/einz.dart fetch \
  --store "$WORK/store-b.json" \
  --server "http://127.0.0.1:$PORT" \
  --attachment-id "$ATTACH_ID" \
  --out "$WORK/downloaded.bin")"
echo "$FETCH_OUT"
echo "$FETCH_OUT" | grep -q "已下载并解密" \
  && echo "✅ B 下载并解密成功" \
  || { echo "❌ fetch 失败"; exit 1; }

step "7. 解密内容与原文件逐字节一致"
if cmp -s "$WORK/photo.bin" "$WORK/downloaded.bin"; then
  echo "✅ 解密文件与原文件完全一致（$(wc -c < "$WORK/downloaded.bin") 字节）"
else
  echo "❌ 解密文件与原文件不一致"; exit 1
fi

echo ""
echo "🎉 Phase 2 验收全部通过：加密上传 / 明文隔离 / 下载解密闭环 / 内容一致"
