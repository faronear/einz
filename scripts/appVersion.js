#!/usr/bin/env node
// 每次打包现场生成的版本号 / 构建号——iOS / Android / macOS / Windows 全平台共用同一套。
//
//   node scripts/appVersion.js                  # 打两行 KEY=VALUE，给 shell eval
//   node scripts/appVersion.js --build-name     # 只打版本号 2609.1810.35（PowerShell 里用）
//   node scripts/appVersion.js --build-number   # 只打构建号 26091810
//
// shell 里这么用（eval 一次，保证版本号与构建号取自同一时刻）：
//   eval "$(node scripts/appVersion.js)"
//   flutter build apk --release --build-name "$APP_BUILD_NAME" --build-number "$APP_BUILD_NUMBER"
//
// 版本号 APP_BUILD_NAME = yymm.ddhh.mm      例 2609.1810.35 = 2026-09-18 10:35（本地时间）
//   iOS/macOS CFBundleShortVersionString、Android versionName、Windows/Linux 的 major.minor.patch。
//   为什么是三段而不是两段的 yymm.ddhh：iOS 侧 flutter_tools 会把不满三段的 build-name 补 0
//   （packages/flutter_tools/lib/src/build_info.dart 的 validatedBuildNameForPlatform），
//   两段的 2609.1810 到 iOS 上会变成 2609.1810.0，与安卓不一致；给满三段，各平台拿到的就是同一个串。
//
// 构建号 APP_BUILD_NUMBER = yymmddhh          例 26091810
//   iOS/macOS CFBundleVersion、Android versionCode。
//   只到小时，因为 Android versionCode 上限 2100000000，带上分钟（2609181035）会溢出。
//   Windows 不传构建号：它的 FILEVERSION 四个字段各 16 位（≤65535），26091810 会撑爆，
//   不传则 flutter 取 0，版本号三段照常生效。

const pad2 = (value) => String(value).padStart(2, '0');

function computeVersion(now) {
  const stamp =
    pad2(now.getFullYear() % 100) + // yy
    pad2(now.getMonth() + 1) + //     mm
    pad2(now.getDate()) + //         dd
    pad2(now.getHours()) + //        hh
    pad2(now.getMinutes()); //       mm
  return {
    // 2609.1810.35
    buildName: `${stamp.slice(0, 4)}.${stamp.slice(4, 8)}.${stamp.slice(8, 10)}`,
    // 26091810
    buildNumber: stamp.slice(0, 8),
  };
}

const { buildName, buildNumber } = computeVersion(new Date());

const arg = process.argv[2];
if (arg === '--build-name') {
  console.log(buildName);
} else if (arg === '--build-number') {
  console.log(buildNumber);
} else {
  console.log(`APP_BUILD_NAME=${buildName}`);
  console.log(`APP_BUILD_NUMBER=${buildNumber}`);
}
