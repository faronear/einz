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

const { execSync } = require('child_process')
const path = require('path')

const builtinAlias = {
  ipxr: 'iPhone XR',
  ipxs: 'iPhone Xs',
  ip11: 'iPhone 11',
  ip11pro: 'iPhone 11 Pro',
  ip11pm: 'iPhone 11 Pro Max',
  ip12: 'iPhone 12',
  ip12mini: 'iPhone 12 mini',
  ip12pro: 'iPhone 12 Pro',
  ip12pm: 'iPhone 12 Pro Max',
  ip13: 'iPhone 13',
  ip13mini: 'iPhone 13 mini',
  ip13pro: 'iPhone 13 Pro',
  ip13pm: 'iPhone 13 Pro Max',
  ip14: 'iPhone 14',
  ip14plus: 'iPhone 14 Plus',
  ip14pro: 'iPhone 14 Pro',
  ip14pm: 'iPhone 14 Pro Max',
  ip15: 'iPhone 15',
  ip15plus: 'iPhone 15 Plus',
  ip15pro: 'iPhone 15 Pro',
  ip15pm: 'iPhone 15 Pro Max',
  ip16: 'iPhone 16',
  ip16plus: 'iPhone 16 Plus',
  ip16pro: 'iPhone 16 Pro',
  ip16pm: 'iPhone 16 Pro Max',
  ip17: 'iPhone 17',
  ip17pro: 'iPhone 17 Pro',
  ip17pm: 'iPhone 17 Pro Max',
  ip17air: 'iPhone Air'
}

const rootDir = path.resolve(__dirname, '..')
let pkgConfig = {}
try {
  pkgConfig = require(path.join(rootDir, 'package.json')).config || {}
} catch (error) {
  pkgConfig = {}
}

const input =
  (process.argv[2] || '').trim() ||
  String(process.env.EMU || pkgConfig.defaultIosEmu || '').trim()

if (
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input)
) {
  console.log(input)
  process.exit(0)
}

const at = input.lastIndexOf('@')
const left = (at === -1 ? input : input.slice(0, at)).trim()
const version =
  at === -1
    ? ''
    : input
        .slice(at + 1)
        .trim()
        .replace(/^iOS\s*/i, '')
const deviceName = pkgConfig[left] || builtinAlias[left.toLowerCase()] || left

const json = JSON.parse(
  execSync('xcrun simctl list devices available -j').toString()
)

// 空规格（裸 npm run app-ios-boot）：有 Booted 直接用它；否则挑可用的
// iPhone 里系统版本最高的那台——任何机器上都能裸跑，不再钉死某机型。
if (!input) {
  const all = []
  for (const [runtimeKey, devices] of Object.entries(json.devices)) {
    if (!/iOS-/.test(runtimeKey)) continue
    for (const d of devices) all.push({ ...d, runtimeKey })
  }
  const booted = all.find(d => d.state === 'Booted')
  if (booted) {
    console.log(booted.udid)
    process.exit(0)
  }
  const iPhones = all.filter(d => /iPhone/i.test(d.name))
  if (iPhones.length === 0) {
    console.error('❌ 本机没有可用的 iPhone 模拟器')
    console.error('   看有哪些：xcrun simctl list devices available')
    process.exit(1)
  }
  iPhones.sort((a, b) => {
    const [aMajor, aMinor] = versionOf(a.runtimeKey)
    const [bMajor, bMinor] = versionOf(b.runtimeKey)
    return bMajor - aMajor || bMinor - aMinor
  })
  console.log(iPhones[0].udid)
  process.exit(0)
}

const runtimeKeyFor = want => `iOS-${want.replace(/\./g, '-')}`
const versionOf = runtimeKey => {
  const matched = runtimeKey.match(/iOS-(\d+)(?:-(\d+))?/)
  return matched ? [Number(matched[1]), Number(matched[2] || 0)] : [0, 0]
}

const matched = []
for (const [runtimeKey, devices] of Object.entries(json.devices)) {
  if (!/iOS-/.test(runtimeKey)) {
    continue
  }
  if (version && !runtimeKey.includes(runtimeKeyFor(version))) {
    continue
  }
  for (const device of devices) {
    if (device.name.toLowerCase() === deviceName.toLowerCase()) {
      matched.push({ ...device, runtimeKey })
    }
  }
}

if (matched.length === 0) {
  console.error(
    `❌ 本机没有匹配的模拟器：${input}（机型「${deviceName}」${
      version ? ` + iOS ${version}` : ''
    }）`
  )
  console.error('   看有哪些：xcrun simctl list devices available')
  process.exit(1)
}

// 同名多台（比如 18.1 和 26.3 各一台）→ 取系统版本最高的那台
matched.sort((a, b) => {
  const [aMajor, aMinor] = versionOf(a.runtimeKey)
  const [bMajor, bMinor] = versionOf(b.runtimeKey)
  return bMajor - aMajor || bMinor - aMinor
})

console.log(matched[0].udid)
