#!/bin/bash
# 清理 macOS debug 运行（npm run app-mac-run / app-mac-run-local）的 dev 数据，
# 等效"测试版重置"——不会碰正式版（默认命名空间）的任何数据。
#
# 清理范围（与 app-mac-run 传入的两个 dart-define 一一对应）：
# - einzDevDataDir=dev        → 容器内 Documents/dev（含锁包所在 einz.sqlite）、
#                               Application Support/dev（附件）、Library/Caches/dev（媒体缓存）
# - einzSecurePrefix=einz.secure.dev. → 文件型 Keychain 里 acct/svce 为 einz.secure.dev.*
#                               的条目（secure_store.dart 的桌面命名空间）
#
# 由 package.json 的 app-mac-run 在 CLEAN=true 时调用；也可单独执行：
#   bash scripts/cleanMacDev.sh
set -euo pipefail

DEV_PREFIX='einz.secure.dev.'
DATA_BASE="$HOME/Library/Containers/cc.tic.einz/Data"

# 运行中的 flutter debug 实例正持有 dev 库（sqlite + WAL），清理前必须先退出
PID_FILE=/tmp/einz_flutter_macos.pid
if [ -f "$PID_FILE" ]; then
  RUNNING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [ -n "$RUNNING_PID" ] && kill -0 "$RUNNING_PID" 2>/dev/null; then
    echo "✋ 检测到 flutter run 仍在运行（pid $RUNNING_PID，$PID_FILE）。"
    echo "   请先结束它（或 LEVEL=2 npm run app-mac-reload 前先 Ctrl-C），再 CLEAN=true 重跑。"
    exit 1
  fi
fi

echo "🧹 清理 macOS dev 数据（正式版数据不受影响）"

# 1) 文件系统：dev 子目录（数据库 / 附件 / 媒体缓存）
for REL in "Documents/dev" "Library/Application Support/dev" "Library/Caches/dev"; do
  TARGET="$DATA_BASE/$REL"
  if [ -e "$TARGET" ]; then
    rm -rf "$TARGET"
    echo "  ✅ 已删 $TARGET"
  else
    echo "  – 无  $TARGET"
  fi
done

# 2) Keychain：acct 为 $DEV_PREFIX* 的 generic password 条目逐条删。
#    dump-keychain 输出里 acct 行形如 0x00000007 <blob>="einz.secure.dev.xxx"，
#    svce 行形如 "svce"<blob>="..."；两行成对出现，配对删除。
DELETED=0
while IFS=$'\t' read -r ACCT SVCE; do
  [ -n "$ACCT" ] || continue
  if security delete-generic-password -a "$ACCT" -s "$SVCE" >/dev/null 2>&1; then
    echo "  ✅ 已删 Keychain: $ACCT"
    DELETED=$((DELETED + 1))
  else
    echo "  ⚠️ 删除失败 Keychain: $ACCT (svce=$SVCE)"
  fi
done < <(security dump-keychain 2>/dev/null | awk -v prefix="$DEV_PREFIX" '
  /<blob>="/ {
    raw=$0
    is_svce = (raw ~ /"svce"<blob>/)
    line=raw
    sub(/.*<blob>="/, "", line); sub(/".*/, "", line)
    if (index(line, prefix) == 1) {
      if (is_svce) { print pending "\t" line; pending="" }
      else pending=line
    }
  }
')
echo "  – Keychain 共删 $DELETED 条"

echo "✨ dev 数据已清空；下次启动即全新安装（会种入 demo 秘境）"
