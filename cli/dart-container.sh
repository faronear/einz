#!/usr/bin/env bash
# Einz TUI/CLI 的 docker 化 dart 运行环境（适合 Debian 等未装系统 dart 的 Linux 机）。
#
# 用法：在 ~/.bashrc 加一行 source 本文件，重开终端后即可：
#   source /path/to/einz/cli/dart-container.sh
#   dart --version                      # 走容器 dart（宿主无系统 dart 时自动接管 dart 命令）
#   tui                                 # 交互式聊天 TUI（需真实终端 tty）
#   dartc run bin/einz.dart sync ...    # 非交互子命令（dartc = 显式容器 dart）
#   dartc compile exe bin/einz_tui.dart -o build/einz-tui-linux   # 容器内编译
#
# 原理：docker run dart:stable（官方镜像，含完整 Dart SDK），仓库挂载为 /app：
#   - /app/cli 为工作目录，path 依赖 ../shared 可见
#   - ~/.pub-cache ↔ 容器 /tmp/.pub-cache   （pub 依赖缓存，避免每次重复下载）
#   - ~/.einz       ↔ 容器 /tmp/.einz       （默认设备身份/密钥目录，持久化）
#   - 以宿主当前 uid:gid 运行 → 生成文件归宿主用户（无 root 权限问题）
# 升级 SDK（"随时更新"只需一条）：docker pull dart:stable
# 环境变量可覆盖：EINZ_DART_IMAGE（镜像）、EINZ_DIR（仓库根）

# 仓库根 = 脚本所在目录的上一级（cli/..），无需手改路径
EINZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EINZ_DART_IMAGE="${EINZ_DART_IMAGE:-dart:stable}"

# 公共 docker run 参数（echo 供 $(...) 分词展开，见 dartc/tui）
_einz_dart_common() {
  echo --rm -i -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$HOME/.pub-cache":/tmp/.pub-cache \
    -v "$HOME/.einz":/tmp/.einz \
    -v "$EINZ_DIR":/app -w /app/cli \
    "$EINZ_DART_IMAGE"
}

# 容器内 dart：非交互子命令（sync / attach / compile …）
dartc() {
  # shellcheck disable=SC2046  # 有意分词：_einz_dart_common 输出选项
  docker run $(_einz_dart_common) dart "$@"
}

# 交互式 TUI（需要 -t 提供 tty/raw 模式）
tui() {
  docker run --rm -it -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$HOME/.pub-cache":/tmp/.pub-cache \
    -v "$HOME/.einz":/tmp/.einz \
    -v "$EINZ_DIR":/app -w /app/cli \
    "$EINZ_DART_IMAGE" dart run bin/einz_tui.dart "$@"
}

# 宿主未装系统 dart 时，让 dart 命令直接走容器（已装则保持宿主 dart 优先；
# 之后若系统装了 dart，重开终端本判断会重新生效）
if ! command -v dart >/dev/null 2>&1; then
  dart() { dartc "$@"; }
fi

echo "🐳 docker 版 dart 就绪（${EINZ_DART_IMAGE}）"
echo "   仓库 ${EINZ_DIR} → /app；dartc=容器 dart；tui=交互聊天；升级: docker pull ${EINZ_DART_IMAGE}"
