/**
 * Multiverse U1 租户隔离测试：两个 Space 的消息互不可见。
 *
 * 验证（PROTOCOL_MULTIVERSE.md §7.1 落地）：
 *   - 设备 A 认证绑定 spaceA、设备 B 认证绑定 spaceB；
 *   - A 发消息后：A 的 /sync 能看到 1 条，B 的 /sync 为 0（跨空间不可见）；
 *   - 反向：B 发消息后 A 仍看不到（server_sequence 按 Space 独立递增）。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）
 */
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
// libsodium-wrappers 的 ESM 入口在 Node ESM 下损坏，统一用 CJS 构建（同 smoke.test.ts）。
const sodium = require('libsodium-wrappers') as typeof import('libsodium-wrappers')
const B64 = sodium.base64_variants.ORIGINAL
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import assert from 'node:assert/strict'

const ROOT = resolve(import.meta.dirname, '..')

let serverProc: ChildProcess | null = null
let tempDir = ''

function freePort (): Promise<number> {
  return new Promise(done => {
    const srv = createServer()
    srv.listen(0, () => {
      const port = (srv.address() as AddressInfo).port
      srv.close(() => done(port))
    })
  })
}

async function waitReady (port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/devices`)
      void res
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

/** 简化测试设备：只做登记/认证/发消息/同步，消息体不加密（服务端只校验结构）。 */
class TestDevice {
  deviceId: string
  keypair: { publicKey: Uint8Array; privateKey: Uint8Array }
  sessionToken = ''

  constructor (deviceId: string) {
    this.deviceId = deviceId
    this.keypair = sodium.crypto_box_keypair()
  }

  async enroll (port: number, inviteCode = ''): Promise<void> {
    const res = await fetch(`http://127.0.0.1:${port}/devices/enroll`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        device_id: this.deviceId,
        public_key: sodium.to_base64(this.keypair.publicKey, B64),
        ...(inviteCode ? { invite_code: inviteCode } : {}),
        device_name: this.deviceId
      })
    })
    assert.equal(res.status, 200, 'enroll should succeed')
    const body = (await res.json()) as { ok: boolean; device_id: string }
    assert.equal(body.ok, true, 'enroll ok')
    this.deviceId = body.device_id
  }

  /** 认证：challenge 可带目标 spaceId（Multiverse；不带则 legacy 回落）。 */
  async auth (port: number, spaceId?: string): Promise<void> {
    const challengeRes = await fetch(`http://127.0.0.1:${port}/auth/challenge`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        device_id: this.deviceId,
        ...(spaceId ? { space_id: spaceId } : {})
      })
    })
    assert.equal(challengeRes.status, 200, 'challenge should succeed')
    const { challenge_id, sealed_challenge } = (await challengeRes.json()) as {
      challenge_id: string
      sealed_challenge: string
    }
    const sealed = sodium.from_base64(sealed_challenge, B64)
    const plaintext = sodium.crypto_box_seal_open(
      sealed,
      this.keypair.publicKey,
      this.keypair.privateKey
    )
    const verifyRes = await fetch(`http://127.0.0.1:${port}/auth/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        challenge_id,
        challenge_plaintext: sodium.to_base64(plaintext, B64)
      })
    })
    assert.equal(verifyRes.status, 200, 'verify should succeed')
    this.sessionToken = ((await verifyRes.json()) as { session_token: string }).session_token
  }

  async postMessage (port: number, messageId: string): Promise<number> {
    const res = await fetch(`http://127.0.0.1:${port}/messages`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.sessionToken}`
      },
      body: JSON.stringify({
        v: 1,
        type: 'text',
        key_version: 1,
        message_id: messageId,
        sender_device_id: this.deviceId,
        nonce: 'x',
        ciphertext: 'y'
      })
    })
    assert.equal(res.status, 200, 'post message should succeed')
    return ((await res.json()) as { server_sequence: number }).server_sequence
  }

  async sync (port: number, after: number): Promise<{ messages: Array<{ message_id: string }>; last_sequence: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/sync?after=${after}`, {
      headers: { Authorization: `Bearer ${this.sessionToken}` }
    })
    assert.equal(res.status, 200, 'sync should succeed')
    return (await res.json()) as { messages: Array<{ message_id: string }>; last_sequence: number }
  }
}

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-isolation-'))
  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: { ...process.env, PORT: String(port), EINZ_DB: join(tempDir, 'einz.sqlite.db') },
    stdio: 'ignore'
  })
  await waitReady(port)

  try {
    // 1) 创建两个 Space（互不相干）
    const createA = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ displayName: '空间A' })
    })
    assert.equal(createA.status, 201, 'create space A should succeed')
    const spaceA = ((await createA.json()) as { spaceId: string }).spaceId
    const createB = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ displayName: '空间B' })
    })
    assert.equal(createB.status, 201, 'create space B should succeed')
    const spaceB = ((await createB.json()) as { spaceId: string }).spaceId
    assert.notEqual(spaceA, spaceB, 'two spaces must be distinct')

    // 2) 两台设备登记（v1 全局 devices；A 首设备自举，B 凭邀请码）
    const devA = new TestDevice('devA')
    await devA.enroll(port)
    await devA.auth(port, spaceA) // 先认证（v1 /invites 需要 session）
    const inviteRes = await fetch(`http://127.0.0.1:${port}/invites`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${devA.sessionToken}`
      },
      body: JSON.stringify({ person_id: 'personB', person_name: 'bob' })
    })
    assert.equal(inviteRes.status, 200, 'invite should succeed')
    const { invite_code: inviteCode } = (await inviteRes.json()) as { invite_code: string }
    const devB = new TestDevice('devB')
    await devB.enroll(port, inviteCode)

    // 3) 各自认证到不同 Space（session 绑定）
    await devA.auth(port, spaceA)
    await devB.auth(port, spaceB)

    // 4) A 在 spaceA 发消息（server_sequence 从 1 起）
    const seqA1 = await devA.postMessage(port, 'a-0001')
    assert.equal(seqA1, 1, 'space A sequence starts at 1')

    // 5) 隔离核心断言：B（spaceB）看不到 A 的消息
    const syncB = await devB.sync(port, 0)
    assert.equal(syncB.messages.length, 0, 'Space B must NOT see Space A messages')

    // 6) A 自己能看到自己的消息
    const syncA = await devA.sync(port, 0)
    assert.equal(syncA.messages.length, 1, 'Space A sees its own message')
    assert.equal(syncA.messages[0].message_id, 'a-0001')

    // 7) 反向：B 发消息后 A 仍看不到；B 的 sequence 独立从 1 起
    const seqB1 = await devB.postMessage(port, 'b-0001')
    assert.equal(seqB1, 1, 'space B sequence starts at 1 independently')
    const syncA2 = await devA.sync(port, syncA.last_sequence)
    assert.equal(syncA2.messages.length, 0, 'Space A must NOT see Space B messages')
    const syncB2 = await devB.sync(port, 0)
    assert.equal(syncB2.messages.length, 1, 'Space B sees its own message')
    assert.equal(syncB2.messages[0].message_id, 'b-0001')

    console.log('✅ 双 Space 隔离测试通过：A 与 B 消息互不可见，sequence 各自独立')
  } finally {
    if (serverProc && serverProc.exitCode === null) serverProc.kill()
    if (tempDir) rmSync(tempDir, { recursive: true, force: true })
  }
}

main()
  .then(() => process.exit(0))
  .catch(err => {
    console.error('❌ 双 Space 隔离测试失败:', err)
    process.exit(1)
  })
