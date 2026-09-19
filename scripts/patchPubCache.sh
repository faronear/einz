#!/usr/bin/env bash
# 给 pub cache 里的第三方插件打 AGP 9 兼容补丁（幂等，可重复执行）。
#
# 背景：主工程用 AGP 9.1.0 + Kotlin DSL，而以下插件自带的 Android 构建脚本
# 太旧，会直接导致 Gradle 配置失败：
#   1. open_filex 4.7.0 —— buildscript 硬编码 AGP 8.1.0，其依赖
#      kotlin-stdlib-jdk8:1.8.20-RC2 是预发布版，已从 Maven Central 下架，
#      解析必 404；
#   2. video_thumbnail 0.5.6 —— 使用已被 AGP 9 移除的 jcenter()，且硬编码
#      compileSdk 33（本机只装 android-34 及以上）。
#
# 补丁打在 ~/.pub-cache 里，pub cache 被清理或重装包后需重新执行本脚本。
# 在 package.json 里对应 "pub-patches"。
set -euo pipefail

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

patchOne() {
  local HOSTED="$1"
  local OPEN_FILEX="$HOSTED/open_filex-4.7.0/android/build.gradle"
  local VIDEO_THUMB="$HOSTED/video_thumbnail-0.5.6/android/build.gradle"

  [[ -f "$OPEN_FILEX" ]] || return 0
  [[ -f "$VIDEO_THUMB" ]] || return 0

  # open_filex：删除整个 buildscript 块（宿主工程已提供 AGP，无需插件自带）
  if grep -q "buildscript" "$OPEN_FILEX"; then
    perl -0pi -e 's/buildscript \{.*?\n\}\n\n//s' "$OPEN_FILEX"
    echo "✓ open_filex [$HOSTED]: 移除 buildscript（AGP 8.1.0 / kotlin-stdlib RC2）"
  else
    echo "• open_filex [$HOSTED]: 已打过补丁，跳过"
  fi

  # video_thumbnail：jcenter() → mavenCentral()；compileSdkVersion 33 → 34
  if grep -q "jcenter()" "$VIDEO_THUMB"; then
    perl -pi -e 's/jcenter\(\)/mavenCentral()/g' "$VIDEO_THUMB"
    echo "✓ video_thumbnail [$HOSTED]: jcenter() → mavenCentral()"
  else
    echo "• video_thumbnail [$HOSTED]: jcenter 已替换，跳过"
  fi
  if grep -q "compileSdkVersion 33" "$VIDEO_THUMB"; then
    perl -pi -e 's/compileSdkVersion 33/compileSdkVersion 34/' "$VIDEO_THUMB"
    echo "✓ video_thumbnail [$HOSTED]: compileSdkVersion 33 → 34"
  else
    echo "• video_thumbnail [$HOSTED]: compileSdk 已升级，跳过"
  fi
}
# 遍历所有镜像目录（pub.dev / pub.flutter-io.cn / ...），镜像切换后缓存里会有多份副本
for HOSTED in "$PUB_CACHE"/hosted/*/; do
  [[ -d "$HOSTED" ]] || continue
  patchOne "$HOSTED"
done

echo "✓ pub cache 补丁完成"
