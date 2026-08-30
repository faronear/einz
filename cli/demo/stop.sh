#!/usr/bin/env bash
# 停止体验用临时 server（保留 store 数据，下次 setup 可继续）。
if [ -f "$(dirname "$0")/server.pid" ]; then
  kill "$(cat "$(dirname "$0")/server.pid")" 2>/dev/null || true
  rm -f "$(dirname "$0")/server.pid"
  echo "✅ server 已停止（store 数据保留在 demo/）"
else
  echo "ℹ️  server 未在运行"
fi
