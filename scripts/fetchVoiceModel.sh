#!/usr/bin/env bash
# 拉取语音转写模型（sense-voice-small int8）到 app/assets/voice_model/。
#
# 定位（aimemo/voiceTranscript.zhcn.md §11，2026-10-12 改回「打包进产物」）：
# 模型二进制**不进 git**（239MB），构建前由本脚本拉取，随 App 打包分发；
# 运行时首次转写才从资产拷到应用目录（见 VoiceTranscriptModel.ensureInstalled）。
#
# 特性：
# - 幂等：文件已存在且大小+sha256 齐全 → 跳过（秒回，可反复挂在构建入口里）；
# - 双源 + 多轮：hf-mirror.com 优先（中国大陆可达），失败回落 huggingface.co；
#   整文件最多 FETCH_ROUNDS 轮（国内网络抖一下是常态，单轮双源不够用）；
# - 快速失败：连接 20s 超时（被墙的主机不等满默认 75s+）；速度低于
#   10KB/s 持续 60s 视为僵死主动 abort（换源比干等强）；
# - 完整性：大小 + sha256 校验，不过则删掉重来（.part 临时，原子替换）；
# - 基线（sha256 / 字节数）与 app/lib/data/voice_transcript_model.dart 的
#   `_files` 单一事实来源对齐——改模型时两处一起改。
#
# 用法（仓库任意位置）：scripts/fetchVoiceModel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/app/assets/voice_model"
FETCH_ROUNDS=3

# 与 voice_transcript_model.dart 的 _files 对齐（name:size:sha256）
FILES=(
  "model.int8.onnx:239233841:c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
  "tokens.txt:315894:f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
)
REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
HOSTS=("https://hf-mirror.com" "https://huggingface.co")

mkdir -p "${DEST}"

# sha256 命令：macOS 是 shasum，Linux 是 sha256sum
if command -v shasum > /dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v sha256sum > /dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
else
  echo "找不到 shasum / sha256sum，无法校验模型完整性" >&2
  exit 1
fi

for entry in "${FILES[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  size="${rest%%:*}"
  want_sha="${rest#*:}"
  file="${DEST}/${name}"

  # 幂等：已存在且大小+sha256 都对 → 跳过
  if [ -f "${file}" ]; then
    actual_size="$(stat -f%z "${file}" 2>/dev/null || stat -c%s "${file}" 2>/dev/null || echo 0)"
    if [ "${actual_size}" = "${size}" ] && [ "$(sha256_of "${file}")" = "${want_sha}" ]; then
      echo "· ${name} 已就绪（${size} 字节，sha256 校验通过），跳过"
      continue
    fi
    echo "· ${name} 已存在但校验不过，重新拉取"
    rm -f "${file}"
  fi

  got=""
  for round in $(seq 1 "${FETCH_ROUNDS}"); do
    for host in "${HOSTS[@]}"; do
      echo "· 拉取 ${name}（$((size / 1048576)) MB）← ${host}（第 ${round}/${FETCH_ROUNDS} 轮）"
      # --fail：HTTP 错误不落 .part；-L 跟随重定向；连接 20s 超时；
      # 僵死（<10KB/s 持续 60s）主动 abort；单连接内再重试 2 次
      if curl --fail --location \
          --connect-timeout 20 --speed-time 60 --speed-limit 10240 \
          --retry 2 --retry-delay 3 \
          --progress-bar \
          -o "${file}.part" "${host}/${REPO}/resolve/main/${name}"; then
        if [ "$(sha256_of "${file}.part")" = "${want_sha}" ]; then
          mv "${file}.part" "${file}"
          got=1
          break 2
        fi
        echo "  sha256 不匹配（${host}），换源重试" >&2
      else
        echo "  下载失败（${host}），换源重试" >&2
      fi
      rm -f "${file}.part"
    done
  done
  if [ -z "${got}" ]; then
    echo "❌ ${name} 所有源 × ${FETCH_ROUNDS} 轮都失败" >&2
    exit 1
  fi
  echo "  ✅ ${name} 就绪"
done

echo "✅ 转写模型就绪：${DEST}"
