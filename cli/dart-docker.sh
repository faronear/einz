#!/usr/bin/env bash
# 一键开发/运行（docker 容器化 dart）——无需系统装 dart、无需 source、无需记命令。
#
# 用法（在仓库任意位置执行即可，脚本自动定位仓库根）：
#   ./cli/dart-docker.sh            # 一键 setup：git pull + 构建 dart-sodium 镜像 + 校验 libsodium
#   ./cli/dart-docker.sh tui        # 进入聊天 TUI（交互；镜像缺失会自动先构建）
#   ./cli/dart-docker.sh dartc <参数>   # 容器内 dart 子命令（如 sync / attach / compile）
#   ./cli/dart-docker.sh build      # 容器内编译 Linux TUI 产物 → cli/build/einz-tui-linux-<架构>-<yymmddhhmm>
#
# 说明：
#   - 镜像 dart-sodium = dart:stable + libsodium（TUI FFI 必需），由 cli/Dockerfile.dev 构建；
#   - 代码改动无需重建镜像（仓库整体挂载 /app，dart run 即最新代码）；
#     只有升级 dart SDK 或换镜像才需要重新 setup；
#   - 身份/密钥持久化：宿主 ~/.einz ↔ 容器 /tmp/.einz；pub 缓存 ~/.pub-cache 同挂；
#   - 容器内工作目录固定为仓库的 cli/（/app/cli），相对路径按此基准写。
set -euo pipefail
export LC_ALL=C # 防非 C locale 下 "$VAR" 后紧跟中文被并入变量名

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # 本脚本目录 = cli/
ROOT="$(cd "$DIR/.." && pwd)"                        # 仓库根
IMG="${DART_IMAGE:-dart-sodium}"

run_container() { # $1: '-it' 或 '-i'；其余为容器内命令
  local tty="$1"
  shift
  docker run --rm "$tty" \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$HOME/.pub-cache":/tmp/.pub-cache \
    -v "$HOME/.einz":/tmp/.einz \
    -v "$ROOT":/app -w /app/cli \
    "$IMG" "$@"
}

build_image() {
  echo "==> 构建开发镜像 ${IMG}（dart:stable + libsodium）…"
  docker build -f "$DIR/Dockerfile.dev" -t "$IMG" "$ROOT"
  echo "✅ 镜像构建完成"
}

ensure_image() { # 镜像缺失时自动构建（代码改动不需要重建）
  docker image inspect "$IMG" >/dev/null 2>&1 || build_image
}

setup() {
  echo "==> 更新代码（git pull）"
  git -C "$ROOT" pull --ff-only || echo "⚠️  git pull 失败（网络或本地有改动），继续构建"
  build_image
  echo "==> 校验镜像内 libsodium"
  if docker run --rm "$IMG" sh -c 'ls /usr/lib/x86_64-linux-gnu/libsodium.so >/dev/null 2>&1'; then
    echo "✅ libsodium 就绪"
  else
    echo "❌ 镜像内缺少 libsodium，请把上方构建/校验输出发我排查"
    exit 1
  fi
  echo ""
  echo "✅ 全部就绪。日常只需："
  echo "   进聊天：    $0 tui"
  echo "   容器 dart： $0 dartc <参数>   （例：$0 dartc run bin/einz.dart sync …）"
  echo "   编 Linux 产物：$0 build   （产物在 cli/build/einz-tui-linux-<架构>-<yymmddhhmm>）"
  echo "   升级 SDK：  $0    （重新执行一键 setup）"
}

case "${1:-setup}" in
  tui)
    shift
    ensure_image
    run_container -it dart run bin/einz_tui.dart "$@"
    ;;
  dartc)
    shift
    ensure_image
    run_container -i dart "$@"
    ;;
  build)
    ensure_image
    echo "==> 容器内执行 cli/build.sh（AOT 编译 → cli/build/einz-tui-linux-<芯片架构>-<时间戳>）…"
    # 复用 build.sh 单一实现（挂载仓库内 /app/cli/build.sh）：自动探测容器 dart、
    # 按平台命名、输出到挂载目录 cli/build/，产物直达宿主
    run_container -i bash build.sh
    ;;
  setup | update | "")
    setup
    ;;
  *)
    echo "用法: $0 [tui|dartc <参数>|build|setup]" >&2
    exit 1
    ;;
esac
