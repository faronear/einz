#!/usr/bin/env node
// 把「短名@系统版本」解析成本机真实存在的模拟器 UDID（供 emuBootIos.sh 调用）。
//
//   node scripts/emuResolveIos.js ip16@26.3        # 短名（见下面别名表）
//   node scripts/emuResolveIos.js "iPhone 16@26.3" # 写机型全名也行
//   node scripts/emuResolveIos.js "iPhone 16"      # 不给版本 → 取系统版本最高的那台
//   node scripts/emuResolveIos.js FF429526-…       # 本来就是 UDID → 原样返回
//
// 为什么不用 UDID：UDID 是每台 Mac 各自生成的，换台机器就失效。
// 机型名 + 系统版本是 Xcode 自带的，任何机器上都能查到，所以跨机器可移植。
//
// 加短名：改下面的 builtinAlias，或在 package.json 的 config 里加一条
// （"ipad": "iPad Pro 13-inch (M4)"），config 里的优先。

const { execSync } = require('child_process');
const path = require('path');

const builtinAlias = {
  ip16: 'iPhone 16',
  ip16plus: 'iPhone 16 Plus',
  ip16pro: 'iPhone 16 Pro',
  ip16pm: 'iPhone 16 Pro Max',
};

const rootDir = path.resolve(__dirname, '..');
let pkgConfig = {};
try {
  pkgConfig = require(path.join(rootDir, 'package.json')).config || {};
} catch (error) {
  pkgConfig = {};
}

const input = (process.argv[2] || '').trim() || String(pkgConfig.default || 'ip16@26.3').trim();

if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input)) {
  console.log(input);
  process.exit(0);
}

const at = input.lastIndexOf('@');
const left = (at === -1 ? input : input.slice(0, at)).trim();
const version = at === -1 ? '' : input.slice(at + 1).trim().replace(/^iOS\s*/i, '');
const deviceName = pkgConfig[left] || builtinAlias[left.toLowerCase()] || left;

const json = JSON.parse(execSync('xcrun simctl list devices available -j').toString());
const runtimeKeyFor = (want) => `iOS-${want.replace(/\./g, '-')}`;
const versionOf = (runtimeKey) => {
  const matched = runtimeKey.match(/iOS-(\d+)(?:-(\d+))?/);
  return matched ? [Number(matched[1]), Number(matched[2] || 0)] : [0, 0];
};

const matched = [];
for (const [runtimeKey, devices] of Object.entries(json.devices)) {
  if (!/iOS-/.test(runtimeKey)) {
    continue;
  }
  if (version && !runtimeKey.includes(runtimeKeyFor(version))) {
    continue;
  }
  for (const device of devices) {
    if (device.name.toLowerCase() === deviceName.toLowerCase()) {
      matched.push({ ...device, runtimeKey });
    }
  }
}

if (matched.length === 0) {
  console.error(`❌ 本机没有匹配的模拟器：${input}（机型「${deviceName}」${version ? ` + iOS ${version}` : ''}）`);
  console.error('   看有哪些：xcrun simctl list devices available');
  process.exit(1);
}

// 同名多台（比如 18.1 和 26.3 各一台）→ 取系统版本最高的那台
matched.sort((a, b) => {
  const [aMajor, aMinor] = versionOf(a.runtimeKey);
  const [bMajor, bMinor] = versionOf(b.runtimeKey);
  return bMajor - aMajor || bMinor - aMinor;
});

console.log(matched[0].udid);
