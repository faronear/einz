#!/usr/bin/env bash
# 语音转写模型打包开关（2026-10-25 老板定）：默认**不**把 239MB 模型打进包，
# 只有 VOICE_MODEL=true 时才拉取模型并临时注入 pubspec 资产声明。
#
# 背景：2026-10-12 7a15ffbe 把「首次使用时下载」改回「打包进产物」，pubspec
# 无条件声明 `assets/voice_model/`——目录里有文件就默默进包。本脚本把这条
# 声明改成运行时注入：pubspec 基线**不含**该声明（进 git）；
# VOICE_MODEL=true 时先跑 fetchVoiceModel.sh，再临时注入声明并执行传入的
# 命令，结束后（含失败，trap 兜底）还原 pubspec。运行时 ensureInstalled
# 的三级解析不用改：包里没资产自然回落下载兜底。
#
# 用法（包装任意 flutter 命令，cwd 不限）：
#   bash scripts/insertVoiceModel.sh <label> flutter run -d macos ...
#   VOICE_MODEL=true npm run app-mac-run        # package.json 内部已包装
# <label> 标识调用入口（macos/ios/android），用于并发互斥与 backup 命名：
#   多个 flutter run 同时带模型时（macos+ios+android 并行），pubspec 只能
#   有一份注入态——用 flock 目录锁互斥（先到者独占注入，后到者阻塞等待，
#   超时 60s 报错退出）；backup 文件名 pubspec.voice_model.<label>.nogit
#   带平台标签，且 .nogit 后缀命中 .gitignore，绝不进 git status/diff。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="${ROOT}/app/pubspec.yaml"
ANCHOR="    - assets/demoSpace/"          # 现有资产行，注入点锚
INJECT="    - assets/voice_model/"

LABEL="${1:-}"; shift
case "${LABEL}" in
  macos|ios|android) ;;
  *) echo "❌ 用法: insertVoiceModel.sh <macos|ios|android> <command...>" >&2; exit 1 ;;
esac
BACKUP="${PUBSPEC}.bak.${LABEL}.nogit"
LOCKDIR="${ROOT}/app/.pubspec_voice_model.lock"

restored=0
restore() {
  [ "${restored}" = 1 ] && return 0
  if [ -f "${BACKUP}" ]; then
    mv "${BACKUP}" "${PUBSPEC}"
    restored=1
    echo "· pubspec.yaml 已还原（语音模型声明移除）"
  fi
  rmdir "${LOCKDIR}" 2>/dev/null || true
}
trap restore EXIT

if [ "${VOICE_MODEL:-false}" = "true" ]; then
  echo "▶ VOICE_MODEL=true：拉取语音转写模型并打包进产物"
  bash "${ROOT}/scripts/fetchVoiceModel.sh"
  # 并发互斥：另一入口正持有注入态（长驻 flutter run），等它释放
  acquired=0
  for i in $(seq 1 60); do
    if mkdir "${LOCKDIR}" 2>/dev/null; then acquired=1; break; fi
    [ "${i}" = 1 ] && echo "· 另一入口（macos/ios/android）正持有 pubspec 注入态，等待释放…"
    sleep 1
  done
  [ "${acquired}" = 1 ] || { echo "❌ 等待 pubspec 注入锁超时（60s）——并行 run 请错开或只留一个带模型" >&2; exit 1; }
  # 只匹配真正的声明行（行首空格 + `- `），pubspec 注释里的字样不算
  if grep -qF "${INJECT}" "${PUBSPEC}"; then
    echo "· pubspec.yaml 已含语音模型声明，不重复注入"
  else
    cp "${PUBSPEC}" "${BACKUP}"
    awk -v anchor="${ANCHOR}" -v inject="${INJECT}" '
      !done && $0 == anchor { print; print inject; done=1; next }
      { print }
    ' "${PUBSPEC}" > "${PUBSPEC}.tmp"
    mv "${PUBSPEC}.tmp" "${PUBSPEC}"
    echo "· pubspec.yaml 已临时注入 ${INJECT}（命令结束后自动还原，backup=${BACKUP##*/}）"
  fi
else
  # 默认路径：pubspec 基线本就无声明，模型文件即使躺在目录里也不会进包；
  # 有正式名文件时提示一下（想打包用 VOICE_MODEL=true）
  if ls "${ROOT}"/app/assets/voice_model/model.int8.onnx >/dev/null 2>&1; then
    echo "ℹ assets/voice_model/ 有模型文件，但 VOICE_MODEL 未设 true——本次构建不打包模型（运行时走下载兜底）"
  fi
fi

# 透传执行；EXIT trap 保证 pubspec 还原（命令失败也还原）
"${@}"
