#!/usr/bin/env bash
# ein-tui 一键编译脚本：把 einz_tui.dart AOT 编译成免 Dart 运行时的原生可执行文件。
#
# 用法:   ./build.sh [输出文件名]      （产物统一放 cli/build/；默认 cli/build/einz-tui-<平台>）
# 平台:   在当前操作系统上编译（Dart 官方不支持交叉编译）：
#           Linux 上编译 → Linux 可执行文件；macOS 上编译 → mac 可执行文件；
#           Windows（git-bash/MSYS）编译 → .exe。x64/arm64 随当前机器而定。
# 依赖:   运行时唯一系统依赖是 libsodium（package:sodium 走 FFI），
#           目标机也要装（见编译后提示）；其余全为纯 Dart，无其他依赖。
# 运行:   ./einz-tui-<平台> --store <路径> --server <url>   （TUI 需真实终端）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

OUT_DIR="$DIR/build" # 产物统一目录（勿提交，见 .gitignore）
mkdir -p "$OUT_DIR"

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin)               NAME="${1:-einz-tui-macos}" ;;
  Linux)                NAME="${1:-einz-tui-linux}" ;;
  MINGW*|MSYS*|CYGWIN*) NAME="${1:-einz-tui.exe}" ;;
  *)                    NAME="${1:-einz-tui}" ;;
esac
OUT="$OUT_DIR/$NAME"

echo "==> 编译 einz_tui.dart → ${OUT}（AOT 原生，免 Dart 运行时）"
dart compile exe bin/einz_tui.dart -o "$OUT"
echo ""
echo "✅ 编译成功: ${OUT}（$(du -h "$OUT" | cut -f1)）"
echo ""

# ---- libsodium 运行时依赖检测与提示 ----
has_libsodium=0
case "$PLATFORM" in
  Darwin)
    if ls /opt/homebrew/lib/libsodium.* >/dev/null 2>&1 || ls /usr/local/lib/libsodium.* >/dev/null 2>&1; then has_libsodium=1; fi ;;
  Linux)
    if ldconfig -p 2>/dev/null | grep -qi 'libsodium\.so'; then has_libsodium=1; fi ;;
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
echo "   （不带参数则使用默认 store 与 config.json/内置服务器地址；TUI 需在真实终端中运行）"
