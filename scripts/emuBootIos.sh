#!/usr/bin/env bash
# 启动指定 iOS 模拟器并打开 Simulator.app。
#
# 用法：
#   npm run app-ios-emu-boot                    # 默认 ip16.ios26.3
#   npm run app-ios-emu-boot -- ip16.ios18.1    # 指定 package.json config 里的键
#   npm run app-ios-emu-boot -- FF429526-…      # 或直接给 UDID
#   EMU=ip16.ios18.1 npm run app-ios-emu-boot   # 用环境变量改默认
#
# 启动后跑 App：npm run app-ios-emu-run-local（默认就打当前启动的那台）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-${EMU:-ip16.ios26.3}}"
udid="$(bash "${SCRIPT_DIR}/emuUdidIos.sh" "${target}")"

echo "▶ 启动模拟器 ${target} (${udid})"
if ! xcrun simctl boot "${udid}" 2>/dev/null; then
  echo "（已在运行，跳过 boot）"
fi
open "$(xcode-select -p)/Applications/Simulator.app"
xcrun simctl list devices booted
