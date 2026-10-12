#!/usr/bin/env bash
# 输出 TURN 的 dart-define 参数（stdout 只含参数；提示走 stderr）。
#
# 为什么存在：TURN 凭证/地址走编译期 dart-define（docs/TURN.md §2），但
# package.json 里的 release 打包脚本（app-apk-build / app-ios-build-raw /
# app-mac-build-raw）不经过 app/ios/buildIos.sh，曾漏带该配置 → 正式包
# 没有 TURN，跨网严格 NAT 通话必挂（2026-10-11 补）。
#
# 用法（打包脚本里）：
#   TURN_ARGS="$(bash scripts/turnDefineArgs.sh)"
#   flutter build apk --release $TURN_ARGS ...
#
# 策略与 app/ios/buildIos.sh 同口径：localConfig.turn.json 存在才带；
# 不存在则提示并输出空参数（不拦打包——缺 TURN 只是跨网中继不可用）。
cd "$(dirname "$0")/../app" || exit 1
if [[ -f localConfig.turn.json ]]; then
  echo "--dart-define-from-file=localConfig.turn.json"
  echo "ℹ️  已带上 TURN 配置（localConfig.turn.json）" >&2
else
  echo "⚠️  无 localConfig.turn.json → 本包不带 TURN，跨网通话会打不通。需要的话：cp localConfig.turn.json 样例填好（见 docs/TURN.md）" >&2
fi
