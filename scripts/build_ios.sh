#!/usr/bin/env bash
# 打包 iOS App 的便捷入口（自动带上本机本地配置）。
#
# 用法（透传 flutter build 参数）：
#   ./scripts/build_ios.sh                     # 等价 flutter build ios
#   ./scripts/build_ios.sh --release           # 等价 flutter build ios --release
#   ./scripts/build_ios.sh -t device           # 等价 flutter build ios -t device
#
# 若 app/local_config.json 存在则自动加 --dart-define-from-file=local_config.json：
# 读取本机本地配置（不入 git）覆盖 kEinzServer 等启动参数——无需直接改
# server_settings.dart、不污染 commit。模板见 app/local_config.example.json。
#
# 调试场景 flutter run 同样支持 --dart-define-from-file（手动加参数即可）：
#   flutter run --dart-define-from-file=local_config.json -d <UDID>
set -euo pipefail
cd "$(dirname "$0")/../app"

DART_DEFINE=()
if [[ -f local_config.json ]]; then
  DART_DEFINE=(--dart-define-from-file=local_config.json)
  echo "📄 使用本机配置 local_config.json（覆盖 kEinzServer 等启动参数）"
fi

flutter build ios "$@" "${DART_DEFINE[@]}"
