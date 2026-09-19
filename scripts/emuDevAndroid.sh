#!/usr/bin/env bash
# 一条命令搞定：启动安卓模拟器（后台）→ 等它完全开机 → 前台跑 einz app。
#
#   npm run app-apk-emu-dev          # 本地配置（等同 app-apk-emu-run-local）
#   npm run app-apk-emu-dev -- remote   # 远程配置（等同 app-apk-emu-run-remote）
#   npm run app-apk-emu-dev -- local-new # 先重装再跑本地配置
#
# 前台终端跑的是 flutter run，Ctrl+C 只退出 flutter，模拟器保持运行；
# 下次再跑本脚本会检测到模拟器已在，直接跳过 boot。
set -euo pipefail

EMULATOR_BIN="$HOME/Library/Android/sdk/emulator/emulator"
AVD_NAME="einz_emu"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

MODE="${1:-local}"

# 1. 模拟器已在就不重复启动
if "$ADB" devices | grep -q "emulator-5554"; then
  echo "✅ 模拟器 emulator-5554 已在运行，跳过启动"
else
  echo "▶ 启动模拟器 ${AVD_NAME}（后台）…"
  nohup "$EMULATOR_BIN" -avd "$AVD_NAME" >/dev/null 2>&1 &
  echo "▶ 等待 adb 设备上线…"
  "$ADB" wait-for-device
  echo "▶ 等待系统开机完成…"
  until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 2
  done
  echo "✅ 模拟器开机完成"
fi

# 2. 前台跑 app
case "$MODE" in
  local)
    npm run app-apk-emu-run-local
    ;;
  remote)
    npm run app-apk-emu-run-remote
    ;;
  local-new)
    npm run app-apk-emu-run-local-new
    ;;
  remote-new)
    npm run app-apk-emu-run-remote-new
    ;;
  *)
    echo "未知模式: $MODE（可选 local / remote / local-new / remote-new）" >&2
    exit 1
    ;;
esac
