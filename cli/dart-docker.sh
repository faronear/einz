#!/usr/bin/env bash
# 一键开发/运行（docker 容器化 dart）——无需系统装 dart、无需 source、无需记命令。
#
# 用法（在仓库任意位置执行即可，脚本自动定位仓库根）：
#   ./cli/dart-docker.sh            # 一键 setup：git pull + 构建 dart-sodium 镜像 + 校验 libsodium
#   ./cli/dart-docker.sh tui        # 进入聊天 TUI（交互；镜像缺失会自动先构建）
#   ./cli/dart-docker.sh dartc <参数>   # 容器内 dart 子命令（如 sync / attach / compile）
#   ./cli/dart-docker.sh build      # 容器内编译 Linux TUI 产物 → _release.gitomit/einz-tui-linux-<架构>-<yymmddhhmm>
#
# 说明：
#   - 镜像 dart-sodium = dart:stable + libsodium（TUI FFI 必需），由 cli/Dockerfile.dart-sodium 构建；
#   - 代码改动无需重建镜像（仓库整体挂载 /app，dart run 即最新代码）；
#     只有升级 dart SDK 或换镜像才需要重新 setup；
#   - 身份/密钥持久化：宿主 ~/.einz ↔ 容器 /tmp/.einz；pub 缓存 ~/.pub-cache 同挂；
#   - 容器内工作目录固定为仓库的 cli/（/app/cli），相对路径按此基准写。
set -euo pipefail
export LC_ALL=C # 防非 C locale 下 "$VAR" 后紧跟中文被并入变量名

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # 本脚本目录 = cli/
ROOT="$(cd "$DIR/.." && pwd)"                        # 仓库根
IMG="${DART_IMAGE:-dart-sodium}"

# 身份策略（老板 2026-10-13 修订）：/root/.einz 是真正的身份仓库——sudo 运行的
# 目的就是用它，因此 sudo 视同 root（挂 /root 的 pub 缓存与 .einz），直接 root
# 登录同样放行；普通用户运行才提示身份差异（用的是自家 ~/.einz）。
if [ "$(id -u)" = "0" ]; then
  REAL_HOME="/root"
  REAL_UID=0
  REAL_GID=0
elif [ -n "${SUDO_USER:-}" ]; then
  echo "❌ 不支持的调用方式：sudo 身份不完整（SUDO_USER=$SUDO_USER 但 uid 非 0）。"
  echo "   请直接 sudo ./dart-docker.sh，或以 root 登录后运行。"
  exit 1
else
  REAL_HOME="${DART_PUB_CACHE_HOME:-$HOME}"
  REAL_UID="$(id -u)"
  REAL_GID="$(id -g)"
  # 普通用户运行：真仓库就是他自己的 ~/.einz、缓存就是他自己的 ~/.pub-cache，
  # 与 root 身份互不相通，各自独立成套（不提示、不干预——老板 2026-10-13）。
fi

run_container() { # $1: '-it' 或 '-i'；其余为容器内命令
  local tty="$1"
  shift
  docker run --rm "$tty" \
    -u "$REAL_UID:$REAL_GID" -e HOME=/tmp \
    -v "$REAL_HOME/.pub-cache":/tmp/.pub-cache \
    -v "$REAL_HOME/.einz":/tmp/.einz \
    -v "$ROOT":/app -w /app/cli \
    "$IMG" "$@"
}

build_image() {
  echo "==> 构建开发镜像 ${IMG}（dart:stable + libsodium）…"
  docker build -f "$DIR/Dockerfile.dart-sodium" -t "$IMG" "$DIR"
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
  echo "   容器 dart： $0 dartc <参数>   （例：$0 dartc run bin/einz_tui.dart --store demo/s1.json …）"
  echo "   编 Linux 产物：$0 build   （产物在 _release.gitomit/einz-tui-linux-<架构>-<yymmddhhmm>）"
  echo "   升级 SDK：  $0    （重新执行一键 setup）"
}

case "${1:-setup}" in
  tui)
    shift
    ensure_image
    # 按入库 lockfile 强制解析：lockfile 与 pubspec 不符或缓存残留旧包时直接报错，
    # 避免静默解析出不兼容版本（曾致首次安装时报 SodiumSumoInit 旧 API 编译错）
    run_container -i dart pub get --enforce-lockfile
    # 内核快照缓存（cn1 实测 2026-10-13）：dart run 每次 JIT 编译整个 TUI ~15s
    # （cn1 CPU 慢，dart run 不落内核缓存）——改为 compile kernel 一次（~2s，源码
    # 未变则跳过重编）后 dart 直跑 dill（~2s）。dill 放 cli/.dart_tool/，随仓库走。
    dill=".dart_tool/einz_tui.dill"
    stale=1
    if [ -f "$ROOT/cli/$dill" ]; then
      # 任一源文件（bin/lib + pubspec）比 dill 新即过期 → 重编
      if [ -z "$(find "$ROOT/cli/bin" "$ROOT/cli/lib" "$ROOT/cli/pubspec.yaml" -newer "$ROOT/cli/$dill" -print -quit 2>/dev/null)" ]; then
        stale=0
      fi
    fi
    if [ "$stale" = 1 ]; then
      echo "==> 编译内核快照（源码有改动或首次启动；之后启动免编译）…"
      run_container -i dart compile kernel -o "$dill" bin/einz_tui.dart
    fi
    run_container -it dart "$dill" "$@"
    ;;
  dartc)
    shift
    ensure_image
    run_container -i dart "$@"
    ;;
  build)
    ensure_image
    echo "==> 容器内执行 cli/buildTui.sh（AOT 编译 → _release.gitomit/einz-tui-linux-<芯片架构>-<时间戳>）…"
    # 复用 buildTui.sh 单一实现（挂载仓库内 /app/cli/buildTui.sh）：自动探测容器 dart、
    # 按平台命名、输出到挂载的 _release.gitomit/，产物直达宿主
    run_container -i bash buildTui.sh
    ;;
  setup | update | "")
    setup
    ;;
  *)
    echo "用法: $0 [tui|dartc <参数>|build|setup]" >&2
    exit 1
    ;;
esac
