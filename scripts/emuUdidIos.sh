#!/usr/bin/env bash
# 解析出一个 iOS 模拟器的 UDID，供 boot / run 脚本复用。
#
# 用法：
#   bash scripts/emuUdidIos.sh ip16.ios26.3   # 取 package.json config 里的同名键
#   bash scripts/emuUdidIos.sh FF429526-…     # 不是 config 键就原样返回（可直接给 UDID 或设备名）
#   bash scripts/emuUdidIos.sh                # 不给参数 → 当前已启动的第一个模拟器
#
# npm 的 -- 参数会原样传进来，所以：
#   npm run app-ios-emu-boot -- ip16.ios26.3
set -euo pipefail

key="${1:-}"

# 1) 给了参数：先当 package.json 的 config 键查
#    · npm 跑脚本时会导出 npm_package_config_<键>（键名带点也能取）
#    · 直接 bash 调用时没有这个环境变量，兜底用 node 读仓库根的 package.json
if [[ -n "${key}" ]]; then
  from_config="$(printenv "npm_package_config_${key}" 2>/dev/null || true)"
  if [[ -z "${from_config}" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    from_config="$(node -p "require('${root}/package.json').config['${key}'] || ''" 2>/dev/null || true)"
  fi
  printf '%s' "${from_config:-${key}}"
  exit 0
fi

# 2) 没给参数：用当前已启动的那台
booted="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
if [[ -z "${booted}" ]]; then
  echo "❌ 没有已启动的模拟器。先跑：npm run app-ios-emu-boot [-- ip16.ios26.3]" >&2
  exit 1
fi
printf '%s' "${booted}"
