#!/usr/bin/env bash
# 启动 iOS 模拟器 —— 「选哪一台」的复杂度和灵活性都集中在这里。
#
#   npm run app-ios-boot                     # 默认 ip16@26.3
#   npm run app-ios-boot -- ip16@26.3        # 短名@系统版本（推荐，跨机器通用）
#   npm run app-ios-boot -- ip16pro@26.3     # iPhone 16 Pro / iOS 26.3
#   npm run app-ios-boot -- ip16@18.1        # iPhone 16 / iOS 18.1
#   npm run app-ios-boot -- "iPhone 16@26.3" # 写机型全名也行
#   npm run app-ios-boot -- FF429526-A7EE-…  # 直接给 UDID
#   EMU=ip16@18.1 npm run app-ios-boot       # 用环境变量改默认
#
# 短名表见 scripts/emuResolveIos.js 的 builtinAlias（ip16 / ip16plus / ip16pro / ip16pm），
# 也可以在 package.json 的 config 里加（"ipad": "iPad Pro 13-inch (M4)"）。
#
# 跑 App 永远打「当前已启动的那台」（纯 booted 语义）：
#   npm run app-ios-emu-run-local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

spec="${1:-${EMU:-}}"
udid="$(node "${SCRIPT_DIR}/emuResolveIos.js" "${spec}")"

echo "▶ 模拟器 ${spec:-默认} → ${udid}"
if xcrun simctl boot "${udid}" 2>/dev/null; then
  echo "✅ 已启动"
else
  echo "（已在运行，跳过 boot）"
fi
# Xcode 27 起不再随附 Simulator.app（simctl 独立工作）；模拟器 GUI 改由
# DeviceHub（Xcode.app/Contents/Applications/DeviceHub.app）承担——有就开它，
# 没有就跳过（flutter run 也会自己唤起模拟器窗口）。
SIM_APP="$(xcode-select -p)/Applications/Simulator.app"
if [ -d "$SIM_APP" ]; then
  open "$SIM_APP"
else
  echo "（本机 Xcode 无 Simulator.app（Xcode 27+ 已移除），跳过开 GUI）"
  echo "  看模拟器界面：open -b com.apple.dt.Devices   # DeviceHub"
  echo "  或直接 flutter run，会自动把模拟器窗口带到前台"
fi
xcrun simctl list devices booted
