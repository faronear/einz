#!/usr/bin/env bash
# ein-tui 一键编译脚本：把 einz_tui.dart AOT 编译成免 Dart 运行时的原生可执行文件。
#
# 用法:   ./build.sh [输出文件名]      （产物统一放 cli/build/；默认文件名带版本号：
#                                        cli/build/einz-tui-<版本>-<平台>，便于新旧对比）
# 平台:   在当前操作系统上编译（Dart 官方不支持交叉编译）：
#           Linux 上编译 → Linux 可执行文件；macOS 上编译 → mac 可执行文件；
#           Windows（git-bash/MSYS）编译 → .exe。x64/arm64 随当前机器而定。
# 依赖:   运行时唯一系统依赖是 libsodium（package:sodium 走 FFI），
#           目标机也要装（见编译后提示）；其余全为纯 Dart，无其他依赖。
# 运行:   ./einz-tui-<平台> --store <路径> --server <url>   （TUI 需真实终端）
set -euo pipefail
# 强制 C locale：非 C locale 下 bash 会把 $VAR 后紧跟的非 ASCII 字节并入变量名
# （曾致 "$OUT（…"、"$DART）…" 报 unbound variable）；C locale 下变量名只认 ASCII
export LC_ALL=C
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

OUT_DIR="$DIR/build" # 产物统一目录（勿提交，见 .gitignore）
mkdir -p "$OUT_DIR"

# 版本号：取 cli/pubspec.yaml 的 version 写入产物文件名（便于新旧版本对比）
VERSION="$(sed -n 's/^version: *//p' pubspec.yaml | head -1 | tr -d '[:space:]')"
[ -n "$VERSION" ] || VERSION="dev"

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin)               NAME="${1:-einz-tui-${VERSION}-macos}" ;;
  Linux)                NAME="${1:-einz-tui-${VERSION}-linux}" ;;
  MINGW*|MSYS*|CYGWIN*) NAME="${1:-einz-tui-${VERSION}.exe}" ;;
  *)                    NAME="${1:-einz-tui-${VERSION}}" ;;
esac
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
