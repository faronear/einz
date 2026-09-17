#!/usr/bin/env bash
# Einz iOS 打包 / 安装脚本 —— 一条命令打 Ad Hoc 或 App Store 包。
#
# 用法（仓库任意位置都能跑，脚本自己切到 app/）：
#   app/ios/buildIos.sh adhoc                     # 打 Ad Hoc IPA
#   app/ios/buildIos.sh adhoc --install           # 打完直接装到手机（默认 iPhone 11）
#   app/ios/buildIos.sh adhoc --install --device <UDID>
#   app/ios/buildIos.sh appstore                  # 打 App Store / TestFlight IPA（不上传）
#   app/ios/buildIos.sh appstore --upload         # 打完上传到 App Store Connect
#
# 两条渠道面向的人群（bundle id 相同 = 同一个 App、同一个数据容器）：
#   adhoc     已登记 UDID 的设备（自己/伴侣的手机，最多 100 台/年），可 devicectl 直装
#   appstore  TestFlight 试用 / 将来上架；无需登记 UDID，但不能直装到手机
#
# appstore --upload 需要的环境变量（App Store Connect API key，见 docs/IOS.md §4）：
#   ASC_API_KEY_ID   Key ID
#   ASC_API_ISSUER   Issuer ID
#   （私钥 .p8 放 ~/private_keys/AuthKey_<KeyID>.p8 等 altool 默认搜索位置）
set -euo pipefail

# ---------- 固定配置（改这里即可换机器/换 App）----------
readonly TEAM_ID="CQ6733CTMV"                       # Faronear Co. Ltd.（付费账号）
readonly BUNDLE_ID="cc.tic.einz.ios"
readonly PROFILE_ADHOC="Einz Dist Adhoc"
readonly PROFILE_STORE="Einz Dist AppStoreConnect"
readonly DEFAULT_DEVICE="00008030-0005306011F9402E" # iPhone 11（luk_ip11_210700）

# ---------- 参数解析 ----------
CHANNEL="${1:-}"
if [[ "${CHANNEL}" != "adhoc" && "${CHANNEL}" != "appstore" ]]; then
  cat >&2 <<'USAGE'
用法: app/ios/buildIos.sh <adhoc|appstore> [选项]

  adhoc                       打 Ad Hoc 包（面向已登记 UDID 的设备）
    --install                 打完用 devicectl 装到手机
    --device <UDID>           指定设备（默认 iPhone 11 00008030-0005306011F9402E）

  appstore                    打 App Store / TestFlight 包（只出 IPA）
    --upload                  打完上传到 App Store Connect（需 ASC_API_KEY_ID / ASC_API_ISSUER）

  -h | --help                 显示本帮助
USAGE
  exit 64
fi
shift

DO_INSTALL=0
DO_UPLOAD=0
DEVICE="${DEFAULT_DEVICE}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    --upload) DO_UPLOAD=1 ;;
    --device)
      DEVICE="${2:-}"
      if [[ -z "${DEVICE}" ]]; then echo "❌ --device 需要一个 UDID" >&2; exit 64; fi
      shift
      ;;
    -h | --help) exec "$0" ;;
    *) echo "❌ 未知参数: $1（-h 看用法）" >&2; exit 64 ;;
  esac
  shift
done

if [[ "${CHANNEL}" == "appstore" && "${DO_INSTALL}" == 1 ]]; then
  echo "❌ App Store 包不能直装到手机（只能 TestFlight / 上架安装）——去掉 --install" >&2
  exit 64
fi

# ---------- 定位 flutter 与 app 目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${APP_DIR}"

FLUTTER="$(command -v flutter || true)"
if [[ -z "${FLUTTER}" && -x "${HOME}/development/flutter/bin/flutter" ]]; then
  FLUTTER="${HOME}/development/flutter/bin/flutter"
  export PATH="${HOME}/development/flutter/bin:${PATH}"
fi
if [[ -z "${FLUTTER}" ]]; then
  echo "❌ 找不到 flutter：请先 export PATH=\"\${HOME}/development/flutter/bin:\${PATH}\"" >&2
  exit 1
fi
echo "▶ flutter: ${FLUTTER}"

# ---------- 1) SPM 必须关闭（用 CocoaPods + 本地 libsodium pod）----------
if "${FLUTTER}" config --list 2>/dev/null | grep -q 'enable-swift-package-manager: true'; then
  echo "▶ 关闭 Swift Package Manager（工程依赖 CocoaPods 的 libsodium pod）…"
  "${FLUTTER}" config --no-enable-swift-package-manager >/dev/null
fi

# ---------- 2) 签名证书 ----------
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${TEAM_ID}"; then
  cat >&2 <<ERR
❌ 钥匙串里没有 ${TEAM_ID} 的 Apple Distribution 证书。
   补一步（证书目录 /Volumes/repodisk/simsim_key/cert-apple-苹果应用证书/20260914/）：
     security import <3_证书.p12> -k ~/Library/Keychains/login.keychain-db -P <口令> -A
   （口令在同目录 3_certpassword.simsim.js）
ERR
  exit 1
fi
echo "✅ 证书: Apple Distribution … (${TEAM_ID})"

# ---------- 3) 对应的 mobileprovision 是否已装到本机 ----------
PROFILE_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
profile_exists() { # $1 = profile 名
  local f xml
  [[ -d "${PROFILE_DIR}" ]] || return 1
  for f in "${PROFILE_DIR}"/*.mobileprovision; do
    [[ -e "$f" ]] || continue
    xml="$(security cms -D -i "$f" 2>/dev/null || true)"
    [[ -n "$xml" ]] || continue
    if printf '%s' "$xml" | grep -q "<string>$1</string>"; then return 0; fi
  done
  return 1
}

if [[ "${CHANNEL}" == "adhoc" ]]; then
  PROFILE_NAME="${PROFILE_ADHOC}"
  PLIST="ios/exportOptionsAdhoc.plist"
else
  PROFILE_NAME="${PROFILE_STORE}"
  PLIST="ios/exportOptionsAppStore.plist"
fi

if ! profile_exists "${PROFILE_NAME}"; then
  cat >&2 <<ERR
❌ 本机缺少 ${CHANNEL} 用的描述文件「${PROFILE_NAME}」（bundle ${BUNDLE_ID}）。
   补一步：developer.apple.com → Certificates, Identifiers & Profiles → Profiles
   → 下载 ${PROFILE_NAME} → 复制为：
     ~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision
   本机已知 UUID（换机器时直接对号入座）：
     App Store → eb4be29b-a197-4813-b11e-a400232b0472
     Ad Hoc    → 458acdea-8f20-4a6d-99fa-6c824506749a
   （已从别的 Mac 拷过证书时别忘了这一步：复制文件名必须是 UUID，Xcode 按 UUID 索引）
ERR
  exit 1
fi
echo "✅ 描述文件: ${PROFILE_NAME}"

# ---------- 4) SDK 版本预检（App Store 上传要求 iOS 26 SDK 起）----------
# Apple 自 2026-04-28 起拒收低于 iOS 26 SDK 的上传包（Transporter 报
# "SDK version issue ... must be built with the iOS 26 SDK or later"）。
# 与其打完包才在上传时被拒，不如开局就拦住。Ad Hoc 走 devicectl 直装，不受此限，
# 所以只在 appstore 渠道硬拦；adhoc 渠道仅打印供参考。
readonly MIN_SDK_MAJOR_STORE=26
XCODE_DEV="$(xcode-select -p 2>/dev/null || true)"
SDK_VERSION="$(xcrun --show-sdk-version --sdk iphoneos 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"
echo "▶ Xcode: ${XCODE_DEV}（iOS SDK ${SDK_VERSION:-未知}）"
if [[ "${CHANNEL}" == "appstore" ]]; then
  if [[ -z "${SDK_MAJOR}" ]] || (( SDK_MAJOR < MIN_SDK_MAJOR_STORE )); then
    cat >&2 <<ERR
❌ 当前 iOS SDK 是 ${SDK_VERSION:-未知}，App Store Connect 只收 iOS ${MIN_SDK_MAJOR_STORE} SDK 起的包。
   换用带 iOS 26 SDK 的 Xcode 再跑（只影响这一条命令，不动全局默认）：
     DEVELOPER_DIR=/Applications/Xcode26.3.app/Contents/Developer npm run app-ios-build-appstore
   或全局切换：sudo xcode-select -s /Applications/Xcode26.3.app/Contents/Developer
   （本机 iMac19,1 上不了 macOS 26 Tahoe，Xcode 天花板是 26.3，别去下载 26.4.1+）
ERR
    exit 1
  fi
  echo "✅ SDK: iOS ${SDK_VERSION}（满足上传要求）"
fi

# ---------- 5) 构建 ----------
echo "▶ 构建 ${CHANNEL} IPA（约 1–3 分钟）…"
"${FLUTTER}" build ipa --release --export-options-plist="${PLIST}"
IPA="${APP_DIR}/build/ios/ipa/einz.ipa"
[[ -f "${IPA}" ]] || { echo "❌ 没找到产物 ${IPA}" >&2; exit 1; }
echo "✅ IPA: ${IPA} ($(du -h "${IPA}" | cut -f1))"

# ---------- 5) 安装 / 上传 ----------
if [[ "${CHANNEL}" == "adhoc" ]]; then
  if [[ "${DO_INSTALL}" == 0 ]]; then
    echo "ℹ️  装到手机：app/ios/buildIos.sh adhoc --install [--device <UDID>]"
    exit 0
  fi
  echo "▶ 安装到设备 ${DEVICE}（devicectl 只吃 .app，先解包）…"
  WORK="$(mktemp -d)"
  unzip -q "${IPA}" -d "${WORK}"
  if xcrun devicectl device install app --device "${DEVICE}" "${WORK}/Payload/Runner.app"; then
    echo "✅ 已安装（bundle ${BUNDLE_ID}）。装不上先看：手机是否锁屏 / UDID 是否在 profile 里"
    echo "   xcrun devicectl list devices   # 查 UDID"
  else
    # 常见失败：手机锁屏（device was not unlocked）、UDID 不在 profile 里、
    # 手机没连上/不在同一 Wi-Fi（devicectl 走网络隧道，报 tunnel interrupted / timed out）
    echo "❌ 安装失败。常见原因：" >&2
    echo "   · 手机没连上或不在同一 Wi-Fi（报 tunnel interrupted / timed out → 解锁手机、连上后重试）" >&2
    echo "   · 手机锁屏（提示 device was not unlocked）" >&2
    echo "   · 该设备 UDID 不在 $PROFILE_NAME 里 / 未配对" >&2
    echo "   xcrun devicectl list devices   # 查设备是否 available (paired) 与 UDID" >&2
    rm -rf "${WORK}"
    exit 1
  fi
  rm -rf "${WORK}"
else
  echo "ℹ️  TestFlight / 上架流程：上传后到 App Store Connect 选构建版本。"
  echo "   上传命令（也见 docs/IOS.md §4）："
  echo "     xcrun altool --upload-app -f \"${IPA}\" -t ios \\"
  echo "       --apiKey \"\${ASC_API_KEY_ID}\" --apiIssuer \"\${ASC_API_ISSUER}\""
  if [[ "${DO_UPLOAD}" == 0 ]]; then
    echo "   （加 --upload 让脚本直接传）"
    exit 0
  fi
  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER:-}" ]]; then
    echo "❌ --upload 需要 ASC_API_KEY_ID 与 ASC_API_ISSUER 两个环境变量（见 docs/IOS.md §4）" >&2
    exit 1
  fi
  echo "▶ 上传到 App Store Connect…"
  xcrun altool --upload-app -f "${IPA}" -t ios \
    --apiKey "${ASC_API_KEY_ID}" --apiIssuer "${ASC_API_ISSUER}"
  echo "✅ 上传已提交；等 Apple 处理完（几分钟～几十分钟）即可在 TestFlight 里选版本"
fi
