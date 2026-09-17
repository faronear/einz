#!/usr/bin/env bash
# ein-tui 一键编译脚本：把 einz_tui.dart AOT 编译成免 Dart 运行时的原生可执行文件。
#
# 用法:   ./build.sh [输出文件名]      （产物统一放 cli/build/；默认文件名含系统-架构-时间戳：
#                                        cli/build/einz-tui-<系统>-<架构>-<yymmddhhmm>，如 einz-tui-linux-x64-2609032201）
# 平台/架构: 操作系统优先于架构排序（不同系统产物互不兼容：Mach-O/ELF/PE）：
#            产物只能在对应系统+架构上运行，系统与架构已写入文件名便于区分；
#            Windows（git-bash/MSYS）产物带 .exe。Dart 官方不支持交叉编译。
# 依赖:   运行时唯一系统依赖是 libsodium（package:sodium 走 FFI），
#           目标机也要装（见编译后提示）；其余全为纯 Dart，无其他依赖。
# 运行:   ./einz-tui-<系统>-<架构>-<yymmddhhmm> --store <路径> --server <url>   （TUI 需真实终端）
set -euo pipefail
# 强制 C locale：非 C locale 下 bash 会把 $VAR 后紧跟的非 ASCII 字节并入变量名
# （曾致 "$OUT（…"、"$DART）…" 报 unbound variable）；C locale 下变量名只认 ASCII
export LC_ALL=C
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

OUT_DIR="$DIR/build" # 产物统一目录（勿提交，见 .gitignore）
mkdir -p "$OUT_DIR"

# 时间戳版本 yymmddhhmm：每次打包自动生成、天然唯一（pubspec 的 version 只在
# 发版时更新，不适合做日常产物标识）；旧产物不删除，可并排对比
STAMP="$(date +%y%m%d%H%M)"

# 架构：产物只在对应架构上运行（arm64 ↔ 苹果 M 系/ARM 云主机；x64 ↔ Intel/AMD）
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64)    ARCH_NAME="x64" ;;
  aarch64 | arm64)   ARCH_NAME="arm64" ;;
  i386 | i686 | x86) ARCH_NAME="x86" ;;
  armv7l | armhf)    ARCH_NAME="arm" ;;
  *)                 ARCH_NAME="$ARCH" ;;
esac

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin)               OS_NAME="macos";   EXT="" ;;
  Linux)                OS_NAME="linux";   EXT="" ;;
  MINGW*|MSYS*|CYGWIN*) OS_NAME="windows"; EXT=".exe" ;;
  *)                    OS_NAME="$(printf '%s' "$PLATFORM" | tr '[:upper:]' '[:lower:]')"; EXT="" ;;
esac
NAME="${1:-einz-tui-${OS_NAME}-${ARCH_NAME}-${STAMP}${EXT}}"
OUT="$OUT_DIR/$NAME"

# ---- 定位 dart（Linux 常不在 PATH：~/dart-sdk、flutter 自带、apt 安装） ----
DART="$(command -v dart || true)"
if [ -z "$DART" ]; then
  for cand in \
    "$HOME/dart-sdk/bin/dart" \
    "$HOME/flutter/bin/cache/dart-sdk/bin/dart" \
    /usr/lib/dart/bin/dart \
    /opt/dart-sdk/bin/dart; do
    if [ -x "$cand" ]; then DART="$cand"; break; fi
  done
fi
if [ -z "$DART" ] && command -v flutter >/dev/null 2>&1; then
  DART="$(dirname "$(command -v flutter)")/cache/dart-sdk/bin/dart"
  [ -x "$DART" ] || DART=""
fi
if [ -z "$DART" ]; then
  echo "❌ 未找到 dart 命令。请先安装 Dart SDK，再运行本脚本："
  echo "   方案A（官方一键）: curl -fsSL https://dart.dev/install.sh | bash"
  echo "   方案B（Debian/Ubuntu）: sudo apt install dart   （需先按 https://dart.dev/get-dart 添加 Google 仓库）"
  echo "   方案C（已有 Flutter）: 把 flutter/bin/cache/dart-sdk/bin 加入 PATH"
  echo "   安装后重开终端（或 source ~/.bashrc）让 PATH 生效"
  exit 1
fi

echo "==> 编译 einz_tui.dart → ${OUT}（AOT 原生，免 Dart 运行时；dart: ${DART}）"
"$DART" compile exe bin/einz_tui.dart -o "$OUT"
echo ""
echo "✅ 编译成功: ${OUT}（$(du -h "$OUT" | cut -f1)）"
echo ""

# ---- libsodium 运行时依赖检测与提示 ----
has_libsodium=0
case "$PLATFORM" in
  Darwin)
    if ls /opt/homebrew/lib/libsodium.* >/dev/null 2>&1 || ls /usr/local/lib/libsodium.* >/dev/null 2>&1; then has_libsodium=1; fi ;;
  Linux)
    # ldconfig 在精简容器里可能不存在：退化为直接检查常见安装路径
    if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -qi 'libsodium\.so'; then
      has_libsodium=1
    elif [ -e /usr/lib/x86_64-linux-gnu/libsodium.so ] || [ -e /usr/local/lib/libsodium.so ] || [ -e /usr/lib/libsodium.so ]; then
      has_libsodium=1
    fi ;;
  MINGW*|MSYS*|CYGWIN*)
    if ls libsodium.dll >/dev/null 2>&1; then has_libsodium=1; fi ;;
esac

if [ "$has_libsodium" = "1" ]; then
  echo "✅ 检测到 libsodium，本机可直接运行。"
  echo "   拷贝到目标机时，目标机也需安装 libsodium："
else
  echo "⚠️  本机未检测到 libsodium（运行时必需，sodium FFI 依赖它）："
fi
case "$PLATFORM" in
  Darwin)               echo "   macOS: brew install libsodium" ;;
  Linux)                echo "   Linux: sudo apt install libsodium23   （或 yum/dnf install libsodium）" ;;
  MINGW*|MSYS*|CYGWIN*) echo "   Windows: 把 libsodium.dll 放到可执行文件同目录或加入 PATH" ;;
esac

echo ""
echo "运行示例:"
echo "   ${OUT} --store ~/.einz/myeinz.json --server https://einz.tic.cc"
echo "   （不带参数则使用默认 store 与 localConfig.json/内置服务器地址；TUI 需在真实终端中运行）"
