#!/usr/bin/env bash
# OnlySpace CLI REPL 本机体验环境 —— 一键准备（幂等，可重复运行）。
#
# 原理：在本机同时扮演两台设备（A=你、B=模拟对方），本地起临时 server，
# 之后开两个终端窗口分别运行 run_a.sh / run_b.sh 互发消息即可。
#
# 用法： bash demo/setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="$ROOT/demo"
PORT="${ONLYSPACE_DEMO_PORT:-3901}"
SERVER_URL="http://127.0.0.1:$PORT"

echo "==> 0. 目录准备: $DEMO"
mkdir -p "$DEMO"

echo "==> 1. init 设备 A（你）与设备 B（模拟对方）"
cd "$ROOT"
[ -f demo/store-a.json ] || dart run bin/onlyspace.dart init --store demo/store-a.json --device-id dev-a1 >/dev/null
[ -f demo/store-b.json ] || dart run bin/onlyspace.dart init --store demo/store-b.json --device-id dev-b1 >/dev/null
PUB_A="$(dart run bin/onlyspace.dart pubkey --store demo/store-a.json)"
PUB_B="$(dart run bin/onlyspace.dart pubkey --store demo/store-b.json)"
echo "    A=$PUB_A"
echo "    B=$PUB_B"

echo "==> 2. config（A 生成 Space Key + 密封给 B + 白名单 config.json）"
[ -f demo/config.json ] && [ -f demo/sealed-b.txt ] || \
  dart run bin/onlyspace.dart config \
    --store demo/store-a.json \
    --peer-pubkey "$PUB_B" \
    --space-id space-demo \
    --out-config demo/config.json \
    --out-sealed-peer demo/sealed-b.txt >/dev/null

echo "==> 3. import（B 导入密封 Space Key）"
[ -f demo/store-b.json ] && dart run bin/onlyspace.dart import --store demo/store-b.json --sealed-file demo/sealed-b.txt --space-id space-demo >/dev/null

echo "==> 4. 启动临时 server（后台，端口 ${PORT}）"
if kill -0 "$(cat demo/server.pid 2>/dev/null)" 2>/dev/null; then
  echo "    server 已在运行"
else
  (cd "$ROOT/../server" && ONLYSPACE_CONFIG="$DEMO/config.json" \
    ONLYSPACE_DB="$DEMO/app.db" \
    ONLYSPACE_FILES="$DEMO/files" \
    PORT="$PORT" nohup node dist/app.js >"$DEMO/server.log" 2>&1 & echo $! > "$DEMO/server.pid")
  for i in $(seq 1 30); do
    curl -s -o /dev/null "$SERVER_URL/devices" && break
    sleep 0.3
  done
  echo "    ✅ server 已启动（日志: demo/server.log）"
fi

echo "==> 5. 双端认证"
dart run bin/onlyspace.dart auth --store demo/store-a.json --server "$SERVER_URL" >/dev/null
dart run bin/onlyspace.dart auth --store demo/store-b.json --server "$SERVER_URL" >/dev/null

echo ""
echo "🎉 环境就绪！现在开两个终端窗口："
echo "    终端 1（你）：      bash $DEMO/run_a.sh"
echo "    终端 2（模拟对方）：bash $DEMO/run_b.sh"
echo "  体验完停止 server： bash $DEMO/stop.sh"
