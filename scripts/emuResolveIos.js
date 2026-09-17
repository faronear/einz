#!/usr/bin/env node
// 把「设备名@系统版本」或 UDID 解析成本机真实存在的模拟器 UDID（供 emuBootIos.sh 调用）。
//
// 跨机器可移植：不依赖写死的 UDID——UDID 是每台 Mac 各自生成的，换机器就失效。
// 设备名（"iPhone 16"）和系统版本（26.3）是 Xcode 自带的，任何机器上都能查到。
//
//   node scripts/emuResolveIos.js "iPhone 16@26.3"   # 机型 + 系统版本
//   node scripts/emuResolveIos.js "iPhone 16"        # 同名多台 → 取系统版本最高的
//   node scripts/emuResolveIos.js FF429526-A7EE-…    # 本来就是 UDID → 原样返回

const { execSync } = require('child_process');

const spec = (process.argv[2] || '').trim();
if (!spec) {
  console.error('❌ 需要一个参数：设备名[@系统版本] 或 UDID');
  process.exit(1);
}

if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(spec)) {
  console.log(spec);
  process.exit(0);
}

const at = spec.lastIndexOf('@');
const name = (at === -1 ? spec : spec.slice(0, at)).trim();
const wantVersion = at === -1 ? '' : spec.slice(at + 1).trim().replace(/^iOS\s*/i, '');

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
  if (wantVersion && !runtimeKey.includes(runtimeKeyFor(wantVersion))) {
    continue;
  }
  for (const device of devices) {
    if (device.name.toLowerCase() === name.toLowerCase()) {
      matched.push({ ...device, runtimeKey });
    }
  }
}

if (matched.length === 0) {
  console.error(`❌ 本机没有匹配的模拟器：${spec}`);
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
