#!/usr/bin/env bash
# 一条命令跑完全部测试。本地自检与 CI 共用这一份逻辑（免得"本地跑的和 CI 跑的两套"）。
#
#   scripts/testAll.sh            # 全部：app + shared + cli + server
#   scripts/testAll.sh app        # 只跑 app（analyze + 全量 widget 测试）
#   scripts/testAll.sh shared     # 只跑 shared（analyze + dart test）
#   scripts/testAll.sh cli        # 只跑 cli（analyze + dart test）
#   scripts/testAll.sh server     # 只跑 server（npm test，内部含 build + tsc）
#   scripts/testAll.sh cli --e2e  # 额外跑 cli/test/*.py 的 pty E2E 探针
#
# 不默认跑 `cli/test/*.py`：那些是 **pty E2E 探针**，要先在 3999 端口起一个真 server，
# 还依赖终端尺寸与时序（见 cli/test/cliMultiverseE2E.py 头部说明）——属"手工探针"，
# 加 `--e2e` 才跑，别拖累日常自检与 CI。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY="all"
WITH_E2E="no"
for arg in "$@"; do
  case "$arg" in
    --e2e) WITH_E2E="yes" ;;
    all|app|shared|cli|server) ONLY="$arg" ;;
    *) echo "未知参数：$arg（用法：scripts/testAll.sh [all|app|shared|cli|server] [--e2e]）" >&2; exit 2 ;;
  esac
done

FAILED=()
step() { printf '\n\033[1m──── %s ────\033[0m\n' "$1"; }
pass() { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1"; FAILED+=("$1"); }

# run <标签> <目录> <命令...>
run() {
  local label="$1"; shift
  local dir="$1"; shift
  step "${label}"
  if ( cd "${ROOT}/${dir}" && "$@" ); then pass "${label}"; else fail "${label}"; fi
}

should() { [ "${ONLY}" = "all" ] || [ "${ONLY}" = "$1" ]; }

# ── pubspec.lock 守卫 ───────────────────────────────────────────────────────
# 开发机常把 PUB_HOSTED_URL 指到中国镜像：`pub get` 可能把 lock 里的 pub.dev 源
# 改写成镜像源，那不该进仓库。测试脚本只该"读"仓库 → 跑前快照，跑后若被改写就还原。
LOCK_TMP="$(mktemp -d)"
LOCK_FILES="app/pubspec.lock shared/pubspec.lock cli/pubspec.lock"
lock_bak() { printf '%s/%s' "${LOCK_TMP}" "$(printf '%s' "$1" | tr '/' '_')"; }
snapshot_locks() {
  for f in ${LOCK_FILES}; do
    [ -f "${ROOT}/${f}" ] && cp "${ROOT}/${f}" "$(lock_bak "$f")"
  done
}
restore_locks_if_changed() {
  for f in ${LOCK_FILES}; do
    local bak; bak="$(lock_bak "$f")"
    [ -f "${bak}" ] || continue
    if ! cmp -s "${bak}" "${ROOT}/${f}"; then
      cp "${bak}" "${ROOT}/${f}"
      printf '  ⚠️  %s 被 pub get 改写（多半是本地镜像源），已还原\n' "$f"
    fi
  done
  rm -rf "${LOCK_TMP}"
}

# ensure_pub <目录> <flutter|dart>：只在缺 package_config 时才 pub get。
# CI 首次必需；本地已有就跳过——免得每次跑测试都动一遍 lock。
ensure_pub() {
  local dir="$1" tool="$2"
  [ -f "${ROOT}/${dir}/.dart_tool/package_config.json" ] && return 0
  printf '  · %s 缺 .dart_tool，先 %s pub get\n' "${dir}" "${tool}"
  ( cd "${ROOT}/${dir}" && "${tool}" pub get )
}

snapshot_locks

if should app; then
  ensure_pub app flutter
  run "app · flutter analyze" app flutter analyze
  run "app · flutter test（全量 widget 测试）" app flutter test
fi

if should shared; then
  ensure_pub shared dart
  run "shared · dart analyze" shared dart analyze
  run "shared · dart test（shared/test/*_test.dart）" shared dart test
fi

if should cli; then
  ensure_pub cli dart
  run "cli · dart analyze" cli dart analyze
  run "cli · dart test（cli/test/*_test.dart）" cli dart test
  if [ "${WITH_E2E}" = "yes" ]; then
    step "cli · pty E2E 探针（需要 3999 端口的真 server）"
    if ( cd "${ROOT}/cli" && for f in test/*.py; do printf '  — %s\n' "$f"; python3 "$f" || exit 1; done ); then
      pass "cli · E2E 探针"
    else
      fail "cli · E2E 探针"
    fi
  fi
fi

if should server; then
  if [ -f "${ROOT}/server/package.json" ] && [ ! -d "${ROOT}/server/node_modules" ]; then
    run "server · npm ci" server npm ci
  fi
  run "server · npm test（含 build + tsc + 全部测试）" server npm test
fi

restore_locks_if_changed

printf '\n'
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf '\033[32m全部通过 ✅\033[0m\n'
  exit 0
fi
printf '\033[31m有 %d 项未通过 ❌\033[0m\n' "${#FAILED[@]}"
for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
exit 1
