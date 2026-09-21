#!/usr/bin/env bash
# Einz macOS 桌面版打包脚本 —— 一条命令完成：flutter 构建 → 签名 →（可选）公证
# → staple → 落盘 _release.gitomit/。
# **dev / dist / dist-nonotary 三个渠道都走这一个脚本**，渠道由参数决定（见下）。
#
# 用法（仓库任意位置都能跑）：
#   app/macos/buildMacos.sh                 # 完整流程：签名 + 公证 + staple
#                                           #   → _release.gitomit/einz-gui-macos-dist-v<时间>.zip
#   app/macos/buildMacos.sh --no-notary     # 只 Developer ID 签名，跳过公证（快速自测）
#                                           #   → …/einz-gui-macos-dist-nonotary-v<时间>.zip
#   app/macos/buildMacos.sh --adhoc         # ad-hoc 签名（无证书机器兜底）
#                                           #   → …/einz-gui-macos-dev-v<时间>.zip
#                                           #   异机/从网上下载会被 Gatekeeper 拦，仅本机调试
#   app/macos/buildMacos.sh --server <地址> # 打完立刻拉起刚构建的 app，并把
#                                           #   `--server <地址>` 传给它（调试用，如
#                                           #   --server http://localhost:3000）
#
#   **不给 --server 就不自动打开 app**（老板 2026-09-21）：正式打包只想出产物，
#   不该顺手再起一个 app；要试跑就显式带 --server。
#
# 前置条件（一次性）：
#   1. 钥匙串里有 "Developer ID Application: ..." 证书（security find-identity -p codesigning）
#   2. 公证凭据已存钥匙串：
#      xcrun notarytool store-credentials einz-notary --apple-id <邮箱> --team-id CQ6733CTMV --password <App专用密码>
#
# 背景（2026-09-20 实测定稿）：
#   异机能打开的唯一组合 = Developer ID 签名 + Hardened Runtime + 公证。
#   且 entitlements **不能**带 keychain-access-groups：它只能由 provisioning profile
#   授权，Developer ID 分发没有 profile → 内核 Taskgated 判 Invalid Signature，双击
#   即「应用程序无法打开」。桌面端 Keychain 走**文件型**（SecureStore 里
#   usesDataProtectionKeychain: false），不需要任何 keychain entitlement。
#   沙盒照常保留 —— 沙盒与 Developer ID 完全兼容（当初「沙盒+Keychain+Developer ID
#   三角死锁」的真凶是数据保护 Keychain，换文件型后沙盒版实测启动无错）。
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
SERVER_ARG="" # 非空 = 打完拉起 app 并把它作为 --server 的值传给 app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notary) MODE="no-notary"; shift ;;
    --adhoc)     MODE="adhoc"; shift ;;
    --server)
      # 值必须跟着给：只写 --server 而没有地址时，app 拿不到目标服务器
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "❌ --server 需要一个地址参数（如 --server http://localhost:3000）" >&2
        exit 64
      fi
      SERVER_ARG="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数: $1（见 --help）" >&2; exit 64 ;;
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
# DiagnosticReports indicator=Taskgated）。Developer ID 分发不需要也不该带 profile
# ——去 profile 后 entitlements 里不能再有任何 profile 背书的项（见 Release.entitlements）。
rm -f "$APP/Contents/embedded.provisionprofile"

# ---------- 签名 ----------
# 两个渠道都直接拿仓库里的 Release.entitlements 签：它现在只含三个布尔项
# （沙盒 / 出站网络 / 用户选择文件），没有任何需要 provisioning profile 背书的受限
# entitlement，因此 Developer ID 与 ad-hoc 两种签名都能带着它正常启动（2026-09-20 实测）。
if [[ "$MODE" == "adhoc" ]]; then
  # **不加 `--options runtime`**：ad-hoc 签名没有 Team ID，Hardened Runtime 会打开
  # Library Validation，dyld 加载内嵌 framework 时报 "mapping process and mapped file
  # (non-platform) have different Team IDs" 直接起不来（2026-09-20 本机实测：同一产物
  # 去掉 runtime 就能启动）。Developer ID 那条能用 runtime，是因为所有组件同属一个
  # Team ID；ad-hoc 没有这个前提。
  echo "==> ad-hoc 签名（沙盒；仅本机调试用）"
  find "$APP/Contents/Frameworks" -name "*.framework" \
    -exec codesign -f -s - --timestamp=none {} \;
  codesign -f -s - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "==> Developer ID 签名（沙盒 + Hardened Runtime）"
  # 由深到浅：先签嵌套 framework 再签 app
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
# 产物名跟着**渠道**走（渠道由签名/公证方式决定，与调用者意图无关）：
#   notary    → -dist           Developer ID + 公证，可分发给任何人
#   no-notary → -dist-nonotary  Developer ID 已签但没公证：本机与已放行过的机器能跑，
#                               下载到新机器会被 Gatekeeper 拦——刻意与 -dist 区分，
#                               免得当成可分发产物发出去
#   adhoc     → -dev            ad-hoc 签名（无身份），仅本机调试；异机/下载会被拦
RELEASE_DIR="$REPO_ROOT/_release.gitomit"
mkdir -p "$RELEASE_DIR"
case "$MODE" in
  adhoc)     CHANNEL="dev" ;;
  no-notary) CHANNEL="dist-nonotary" ;;
  *)         CHANNEL="dist" ;;
esac
RELEASE="$RELEASE_DIR/einz-gui-macos-${CHANNEL}-v${APP_BUILD_STAMP}.zip"
rm -f "$RELEASE"
# 用 zip 压缩包而非裸 *.app：*.app 在访达/网盘/跨机搬运中易被改坏扩展属性和
# 签名结构（老板实测：一台 Mac 启动失败后，拷到另一台也跟着"损坏"），
# ditto 打包能完整保留符号链接、权限和资源 fork，解压即用。
ditto -c -k --keepParent --sequesterRsrc "$APP" "$RELEASE"
echo
echo "======= 完成: $RELEASE ======="
ls -lh "$RELEASE"

# ---------- 立刻试跑（仅显式给了 --server 时） ----------
# 拉起的是**构建产物本身**（不是解压 zip；落盘的 zip 是给分发用的，两者内容一致），
# 免得再从访达里找包。默认不拉起——打包就是打包（老板 2026-09-21）。
if [[ -n "$SERVER_ARG" ]]; then
  echo "==> 打开刚构建的 app（--server $SERVER_ARG）"
  open "$APP" --args --server "$SERVER_ARG"
else
  echo "==> 未指定 --server：不自动打开 app（产物已落盘，可自行解压运行）"
fi
