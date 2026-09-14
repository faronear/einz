#!/usr/bin/env bash
# 端到端验收脚本共用件（由 *_e2e.sh / *_check.sh source；`_` 前缀 = 本身不是可执行测试）
#
# 为什么存在：多个验收脚本共用同一段"起服务 + 备两台设备"的样板；散落各处会一起腐化
# ——2026-09-14 复核时发现它们全部因 Multiverse 之后 `config.json` 白名单被废弃而跑不通。
#
# 调用方需先定义：ROOT（仓库根）/ WORK（临时目录）/ PORT / SERVER_PID（可为空）
# 提供：wpath py field_of token_of id_of start_server stop_server pair_up

# ---------- 可移植性 ----------

# 传给 python/node 的路径：Windows(Git Bash) 需 cygpath -m 转混合路径；macOS/Linux 原样输出
wpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# python 解释器：新 macOS 只有 python3，Windows Git Bash 才叫 python
py() {
  if command -v python3 >/dev/null 2>&1; then python3 "$@"; else python "$@"; fi
}

# ---------- store 字段读写 ----------

# field_of <store 文件名> <json 字段>
# Multiverse：device_id / person_id 由服务端分配（enroll 回填），不能再假设 init 传入的
# dev-a1/dev-b1 —— 撤销等接口必须用服务端规范 id，否则 404。
field_of() {
  py -c "import json;print(json.load(open(r'$(wpath "$WORK")/$1')).get('$2') or '')"
}

token_of() { field_of "$1" session_token; }
id_of() { field_of "$1" device_id; }

# ---------- 服务端生命周期 ----------

start_server() {
  # exec 替换 subshell 为 node，使 $! 直接是 node 进程（Git Bash 下 kill subshell 杀不掉子进程）
  (cd "$ROOT/server" && exec env \
    EINZ_DB="$WORK/einz.sqlite.db" \
    EINZ_FILES="$WORK/files" \
    PORT="$PORT" node dist/app.js >"$WORK/server.log" 2>&1) &
  SERVER_PID=$!
  for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/devices" && return 0
    sleep 0.3
  done
  echo "❌ Server 启动失败"; cat "$WORK/server.log"; exit 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/devices" 2>/dev/null && sleep 0.3 || { SERVER_PID=""; return 0; }
  done
  SERVER_PID=""
}

# ---------- 双设备准备（Multiverse）----------

# pair_up [storeA] [storeB]：备好两台设备并让两端持有**同一把 v1 Space Key**。
#   init → A 自举登记 + 口令托管（store 无 Space Key 时自动生成）→ A 生成邀请码
#   → B 凭邀请码登记 + 凭口令接入（key-escrow 取回同一把钥匙）
# 成功后导出 PASSPHRASE；服务已在运行（SERVER_PID 有效）。
pair_up() {
  local storeA="${1:-$WORK/a.json}"
  local storeB="${2:-$WORK/b.json}"
  local server="http://127.0.0.1:$PORT"

  cd "$ROOT/cli"
  dart run bin/einz.dart init --store "$storeA" --device-id dev-a1 >/dev/null
  dart run bin/einz.dart init --store "$storeB" --device-id dev-b1 >/dev/null
  start_server

  dart run bin/einz.dart enroll --store "$storeA" --server "$server" \
    --person personA --device-name A >/dev/null
  dart run bin/einz.dart auth --store "$storeA" --server "$server" >/dev/null
  PASSPHRASE="e2e-escrow-passphrase-1"
  dart run bin/einz.dart escrow --action upload --store "$storeA" \
    --server "$server" --passphrase "$PASSPHRASE" >/dev/null

  local invite
  invite="$(dart run bin/einz.dart invite --store "$storeA" --server "$server" \
    --person personB --name B | sed -n 's/.*: //p')"
  [ -n "$invite" ] || { echo "❌ 邀请码生成失败"; cat "$WORK/server.log" | tail -5; exit 1; }

  dart run bin/einz.dart enroll --store "$storeB" --server "$server" \
    --invite-code "$invite" --person personB --device-name B >/dev/null
  dart run bin/einz.dart auth --store "$storeB" --server "$server" >/dev/null
  dart run bin/einz.dart escrow --action download --store "$storeB" \
    --server "$server" --passphrase "$PASSPHRASE" >/dev/null
}

# assert_contains <输出> <期望子串> <说明>：set -o pipefail 下不要用 `cmd | grep -q`
# （grep 提前退出会让 cmd 收到 SIGPIPE(141)，管道整体非零 → 误判失败）
assert_contains() {
  echo "$1" | grep -q "$2" && echo "✅ $3" || { echo "❌ $3"; echo "$1"; exit 1; }
}
