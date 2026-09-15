/**
 * 回归：设备名字符白名单 + 长度上限（老板 2026-09-16 定）。
 *
 * 只允许中文字 / 英文字母 / 数字 / `_` / `-`，最长 32。
 *  - create/join 携带的名字（多由客户端自动取，如宿主机名、手机型号）→ 消毒
 *    （不合规字符换 `_`），保证**落库的一定合规**；
 *  - POST /devices/name（用户主动改名）→ 不合规直接 400，让客户端提示重输。
 *
 * 客户端同款规则在 shared/lib/src/policy/device_name_policy.dart（改动请同步）。
 *
 * 运行：npm test（tsx test/device_name.test.ts）
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { assertDeviceName, normalizeDeviceName } from '../src/deviceName.js'

const ROOT = join(import.meta.dirname, '..')

/** 所有请求都要带协议版本头（PROTOCOL.md §1：缺头一律 400）。 */
function req (port: number, path: string, init?: RequestInit): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    ...init,
    headers: { 'X-Protocol-Version': '1', ...(init?.headers as Record<string, string> | undefined) }
  })
}

function freePort (): number {
  return 40000 + Math.floor(Math.random() * 20000)
}

async function waitReady (port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`)
      if (res.ok) return
    } catch {}
    await new Promise(r => setTimeout(r, 200))
  }
  throw new Error('server not ready')
}

test('normalizeDeviceName：create/join 的自动名消毒', () => {
  assert.equal(normalizeDeviceName('lukde-MacBook-Pro'), 'lukde-MacBook-Pro') // 合规原样
  assert.equal(normalizeDeviceName('MacBook Pro'), 'MacBook_Pro')
  assert.equal(normalizeDeviceName('iPhone 15 Pro'), 'iPhone_15_Pro')
  assert.equal(normalizeDeviceName('老板的 iPhone'), '老板的_iPhone')
  assert.equal(normalizeDeviceName('  doomship  '), 'doomship') // 首尾空白不是 `_`
  assert.equal(normalizeDeviceName('???'), '___') // 全不合规 → 一串 `_`
  assert.equal(normalizeDeviceName('测'.repeat(50)).length, 32) // 截断到 32
  assert.equal(normalizeDeviceName(''), null) // 空 → null（展示层用 device_id 兜底）
  assert.equal(normalizeDeviceName(undefined), null)
  assert.equal(normalizeDeviceName(42), null)
})

test('assertDeviceName：用户改名不合规 → 400', () => {
  assert.doesNotThrow(() => assertDeviceName('My-Mac_01'))
  assert.doesNotThrow(() => assertDeviceName('老板的电脑'))
  assert.doesNotThrow(() => assertDeviceName('a'.repeat(32))) // 边界：32 正好
  for (const bad of ['', '   ', 'MacBook Pro', 'iPhone15!', '设备。一号', '📱phone', 'a'.repeat(33)]) {
    assert.throws(
      () => assertDeviceName(bad),
      (e: unknown) => e instanceof ApiError && e.code === 'INVALID_REQUEST',
      `应拒收: ${JSON.stringify(bad)}`
    )
  }
})

test('端到端：create 消毒入库，改名不合规被拒', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-devname-'))
  const port = freePort()
  const proc: ChildProcess = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: { ...process.env, PORT: String(port), EINZ_DB: join(dir, 'einz.sqlite.db'), EINZ_FILES: join(dir, 'files') },
    stdio: 'ignore'
  })
  try {
    await waitReady(port)

    // 1) create 携带含空格的自动名 → 落库为消毒后的合规名
    const create = await req(port, '/spaces', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        display_name: 'luk',
        public_key: Buffer.alloc(32, 7).toString('base64'),
        device_name: '老板的 iPhone'
      })
    })
    assert.equal(create.status, 201, 'create space should succeed')
    const { sessionToken } = (await create.json()) as { sessionToken: string }
    const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${sessionToken}` }

    const list = await req(port, '/devices', { headers: auth })
    const devices = ((await list.json()) as { devices: Array<{ device_name: string }> }).devices
    assert.equal(devices.length, 1)
    assert.equal(devices[0].device_name, '老板的_iPhone', 'create 应把空格换成 _')

    // 2) 改名：不合规 400（服务端这道是约束，不只是前端体验）
    for (const bad of ['MacBook Pro', 'iPhone!', '📱', 'a'.repeat(33)]) {
      const res = await req(port, '/devices/name', {
        method: 'POST',
        headers: auth,
        body: JSON.stringify({ device_name: bad })
      })
      assert.equal(res.status, 400, `不合规改名应被拒: ${bad}`)
    }

    // 3) 改名：合规 200 且生效
    const ok = await req(port, '/devices/name', {
      method: 'POST',
      headers: auth,
      body: JSON.stringify({ device_name: '书房-Mac_01' })
    })
    assert.equal(ok.status, 200, '合规改名应成功')
    const list2 = await req(port, '/devices', { headers: auth })
    const devices2 = ((await list2.json()) as { devices: Array<{ device_name: string }> }).devices
    assert.equal(devices2[0].device_name, '书房-Mac_01')
  } finally {
    proc.kill()
  }
})
