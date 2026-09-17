#!/usr/bin/env bash
# 输出要跑 App 的那台模拟器 UDID，供 app-ios-emu-run-* 使用。
#
# 不给参数（默认）：纯 booted 语义——打「当前已启动的那台」。
#                   有多台同时开着会直接报错，避免稀里糊涂打到另一台上。
# 给参数（覆盖）  ：解析成指定的那台，跳过 booted 检查。
#                   EMU=ip16@26.3 npm run app-ios-emu-run-local
#                   （flutter run 会自己把它启动起来，不用先 boot）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

override="${1:-}"
if [[ -n "${override}" ]]; then
  node "${SCRIPT_DIR}/emuResolveIos.js" "${override}"
  exit 0
fi

booted="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' || true)"

if [[ -z "${booted}" ]]; then
  echo "❌ 没有已启动的模拟器。先跑：npm run app-ios-emu-boot [-- ip16@26.3]" >&2
  exit 1
fi

count="$(printf '%s\n' "${booted}" | wc -l | tr -d ' ')"
if (( count > 1 )); then
  echo "❌ 有 ${count} 台模拟器同时开着，不知道该打哪台：" >&2
  xcrun simctl list devices booted >&2
  echo "   关掉多余的：xcrun simctl shutdown <UDID>" >&2
  echo "   或者直接指定：EMU=ip16@26.3 npm run app-ios-emu-run-local" >&2
  exit 1
fi

printf '%s' "${booted}"
