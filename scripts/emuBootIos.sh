#!/usr/bin/env bash
# 启动 iOS 模拟器 —— 「选哪一台」的复杂度和灵活性都集中在这里。
#
#   npm run app-ios-emu-boot                          # 默认取 config.default
#   npm run app-ios-emu-boot -- ip16.ios26.3          # package.json config 里的键
#   npm run app-ios-emu-boot -- "iPhone 16@26.3"      # 机型@系统版本（跨机器可移植）
#   npm run app-ios-emu-boot -- "iPhone 16"           # 只给机型（同名多台取系统版本最高的）
#   npm run app-ios-emu-boot -- FF429526-A7EE-…       # 直接给 UDID
#   EMU="iPhone 16@18.1" npm run app-ios-emu-boot     # 用环境变量改默认
#
# 跑 App 永远打「当前已启动的那台」（纯 booted 语义）：
#   npm run app-ios-emu-run-local
#
# config 的值可以是「机型@系统版本」（推荐，换机器也不用改），
# 也可以是 UDID（只在这台机器上有效）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

spec="${1:-${EMU:-}}"

# 没给参数 → 用 config.default，没有就退回 config 里第一台的机型
if [[ -z "${spec}" ]]; then
  spec="$(printenv "npm_package_config_default" 2>/dev/null || true)"
  [[ -n "${spec}" ]] || spec="$(node -p "require('${ROOT}/package.json').config.default || ''" 2>/dev/null || true)"
  [[ -n "${spec}" ]] || spec="iPhone 16"
fi

# 是 package.json config 的键吗？（键名不含空格和 @）是就取其值继续解析
if [[ "${spec}" != *" "* && "${spec}" != *"@"* ]]; then
  from_config="$(printenv "npm_package_config_${spec}" 2>/dev/null || true)"
  if [[ -z "${from_config}" ]]; then
    from_config="$(node -p "require('${ROOT}/package.json').config['${spec}'] || ''" 2>/dev/null || true)"
  fi
  [[ -n "${from_config}" ]] && spec="${from_config}"
fi

udid="$(node "${SCRIPT_DIR}/emuResolveIos.js" "${spec}")"

echo "▶ 模拟器 ${spec} → ${udid}"
if xcrun simctl boot "${udid}" 2>/dev/null; then
  echo "✅ 已启动"
else
  echo "（已在运行，跳过 boot）"
fi
open "$(xcode-select -p)/Applications/Simulator.app"
xcrun simctl list devices booted
