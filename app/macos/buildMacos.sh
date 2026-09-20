#!/usr/bin/env bash
# Einz macOS 打包脚本 —— 一条命令完成：flutter 构建 → Developer ID 签名 →
# 公证（notarization）→ staple → 落盘 _release.gitomit/。
#
# 用法（仓库任意位置都能跑）：
#   app/macos/buildMacos.sh                    # 完整流程：签名 + 公证 + staple
#   app/macos/buildMacos.sh --no-notary        # 只 Developer ID 签名，跳过公证（快速自测）
#   app/macos/buildMacos.sh --adhoc            # ad-hoc 签名（无证书机器兜底；会删 keychain 组，
#                                              #   Apple Silicon 上 Keychain 不可用——仅本机调试用）
#
# 前置条件（一次性）：
#   1. 钥匙串里有 "Developer ID Application: ..." 证书（security find-identity -p codesigning）
#   2. 公证凭据已存钥匙串：
#      xcrun notarytool store-credentials einz-notary --apple-id <邮箱> --team-id CQ6733CTMV --password <App专用密码>
#
# 为什么必须走这套流程（背景 2026-09-20）：
#   CI ad-hoc 产物在 Apple Silicon 上无法用 Keychain（沙盒应用需要 keychain-access-groups，
#   而 ad-hoc 签名带 keychain 组会被 AMFI 判 Invalid Signature 启动即死）→ StartupGate
#   报"启动初始化失败"。Developer ID 签名 + Hardened Runtime 可以同时保住
#   沙盒 + keychain-access-groups，公证后再无 Gatekeeper"已损坏/无法验证"弹窗。
set -euo pipefail
# 不设 LC_ALL=C：CocoaPods（Ruby）在 C locale 下报 UnicodeNormaliz
# Encoding::CompatibilityError（本机实跑踩过）；本脚本变量名全 ASCII，无此需求

# ---------- 固定配置 ----------
readonly TEAM_ID="CQ6733CTMV"        # Faronear Co. Ltd.（付费账号）
readonly IDENTITY="Developer ID Application: Faronear Co. Ltd. (CQ6733CTMV)"
readonly NOTARY_PROFILE="einz-notary" # notarytool store-credentials 存的 profile 名
readonly ENTITLEMENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Runner/Release.entitlements"

# 统一用 Xcode 26.3（与 buildIos.sh 同一理由：本机天花板，跨机一致）
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode26.3.app/Contents/Developer}"
if [[ ! -d "${DEVELOPER_DIR}" ]]; then
  echo "❌ 找不到 ${DEVELOPER_DIR}（Xcode 26.3）。装好后重跑，或用 DEVELOPER_DIR 指定别的位置" >&2
  exit 1
fi

# ---------- 参数 ----------
MODE="notary" # notary（默认）| no-notary | adhoc
for arg in "$@"; do
  case "$arg" in
    --no-notary) MODE="no-notary" ;;
    --adhoc)     MODE="adhoc" ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数: $arg（见 --help）" >&2; exit 64 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT/app"

# ---------- 证书检查（adhoc 模式跳过） ----------
if [[ "$MODE" != "adhoc" ]]; then
  if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "❌ 钥匙串里没有有效的 ${IDENTITY}" >&2
    echo "   检查: security find-identity -v -p codesigning" >&2
    exit 1
  fi
fi

# ---------- flutter 构建 ----------
find build/macos -name '*.sbak' -print -delete 2>/dev/null || true
eval "$(node ../scripts/appVersion.js)"
echo "==> flutter build macos --release ${APP_BUILD_NAME} (${APP_BUILD_NUMBER})"
flutter build macos --release --build-name "$APP_BUILD_NAME" --build-number "$APP_BUILD_NUMBER"

APP="build/macos/Build/Products/Release/einz.app"

# 删掉 flutter 自动嵌入的本机 Mac Development provisioning profile：
# 它的 ProvisionedDevices 只登记了本机 UUID，拷到别的 Mac 会被内核判
# Taskgated Invalid Signature，双击即"应用程序无法打开"（SIGKILL 实锤，
# DiagnosticReports indicator=Taskgated）。Developer ID 分发不需要 profile
# ——keychain-access-groups 由 Developer ID 签名本身背书。
rm -f "$APP/Contents/embedded.provisionprofile"

# ---------- 签名 ----------
if [[ "$MODE" == "adhoc" ]]; then
  # ad-hoc：删受限 entitlement（keychain 组带 team 前缀，ad-hoc 下 AMFI 判无效签名）
  echo "==> ad-hoc 签名（删 keychain-access-groups；Keychain 在沙盒下将不可用）"
  TMP_ENT="$(mktemp).entitlements"
  plutil -remove keychain-access-groups "$ENTITLEMENTS" -o "$TMP_ENT" 2>/dev/null \
    || cp "$ENTITLEMENTS" "$TMP_ENT"
  find "$APP/Contents/Frameworks" -name "*.framework" \
    -exec codesign -f -s - --timestamp=none --options runtime {} \;
  codesign -f -s - --timestamp=none --options runtime --entitlements "$TMP_ENT" "$APP"
  rm -f "$TMP_ENT"
else
  # Developer ID：entitlements 原样保留（keychain 组合法），Hardened Runtime 必须开
  # --options runtime；公证人要求。先签嵌套 framework 再签 app（由深到浅）。
  echo "==> Developer ID 签名（Hardened Runtime）"
  find "$APP/Contents/Frameworks" -name "*.framework" \
    -exec codesign -f -s "$IDENTITY" --timestamp --options runtime {} \;
  codesign -f -s "$IDENTITY" --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify -v --strict "$APP"
fi

# ---------- 公证 + staple ----------
if [[ "$MODE" == "notary" ]]; then
  # 打 zip 必须用 ditto：Frameworks 里有符号链接，zip 命令会破坏结构导致公证失败
  ZIP_PATH="$REPO_ROOT/.notary-upload.zip"
  echo "==> 打公证用 zip（ditto 保留符号链接）"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP_PATH"

  echo "==> 提交公证（Apple 扫描约 2–10 分钟，--wait 等结果）"
  if ! xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "❌ 公证失败。拉取详细日志：" >&2
    SUBMIT_ID="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output json | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.submissions[0].id)')"
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    rm -f "$ZIP_PATH"
    exit 1
  fi
  rm -f "$ZIP_PATH"

  echo "==> staple（把公证票据钉到 app，离线 Gatekeeper 也能过）"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  echo "==> Gatekeeper 最终校验"
  spctl -a -vv -t exec "$APP"
fi

# ---------- 落盘 ----------
RELEASE_DIR="$REPO_ROOT/_release.gitomit"
mkdir -p "$RELEASE_DIR"
RELEASE="$RELEASE_DIR/einz-gui-macos.${APP_BUILD_STAMP}.app"
rm -rf "$RELEASE"
cp -R "$APP" "$RELEASE"
echo
echo "======= 完成: $RELEASE ======="
ls -lh "$RELEASE"
