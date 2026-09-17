#!/usr/bin/env bash
# 输出「当前已启动的那台模拟器」的 UDID，供 app-ios-emu-run-* 使用（纯 booted 语义）。
#
# 不接参数、不做任何解析——选哪台模拟器是 app-ios-emu-boot 的事，这里只认"已启动的那台"。
# 有多台同时开着会直接报错，避免稀里糊涂打到了另一台上。
set -euo pipefail

booted="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' || true)"

if [[ -z "${booted}" ]]; then
  echo "❌ 没有已启动的模拟器。先跑：npm run app-ios-emu-boot [-- \"iPhone 16@26.3\"]" >&2
  exit 1
fi

count="$(printf '%s\n' "${booted}" | wc -l | tr -d ' ')"
if (( count > 1 )); then
  echo "❌ 有 ${count} 台模拟器同时开着，不知道该打哪台：" >&2
  xcrun simctl list devices booted >&2
  echo "   关掉多余的：xcrun simctl shutdown <UDID>" >&2
  exit 1
fi

printf '%s' "${booted}"
