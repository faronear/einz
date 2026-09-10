#!/usr/bin/env bash
# 运行/构建 App 的本地开发便捷入口（自动带上本机本地配置）。
#
# 用法（透传任意 flutter 命令，第一个参数为 run/build 等）：
#   ./scripts/run_app.sh run -d <UDID>            # 等价 flutter run，自动加本机配置
#   ./scripts/run_app.sh build ios --release      # 等价 flutter build，自动加本机配置
#
# 若 app/local_config.json 存在则自动加 --dart-define-from-file=local_config.json：
# 读取本机本地配置（不入 git）覆盖 kEinzServer 等启动参数——无需直接改
# server_settings.dart、不污染 commit。模板见 app/local_config.example.json。
set -euo pipefail
cd "$(dirname "$0")/../app"

DART_DEFINE=()
if [[ -f local_config.json ]]; then
  DART_DEFINE=(--dart-define-from-file=local_config.json)
  echo "📄 使用本机配置 local_config.json（覆盖 kEinzServer 等启动参数）"
fi

flutter "$@" "${DART_DEFINE[@]}"
