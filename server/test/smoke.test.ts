/**
 * Einz Server 冒烟测试（Phase 0，可验证）
 *
 * 模拟两台设备（Node 侧用 libsodium-wrappers 扮演客户端）：
 *   A 认证 → A 加密发送 → B 认证 → B 增量同步 → B 解密
 * 同时验证：Server 只见密文（明文不出现在任何响应与数据库）、幂等、未登记设备拒绝。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）
 */
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
// libsodium-wrappers 的 ESM 入口在 Node ESM 下损坏，统一用 CJS 构建（同 server/src/crypto.ts）。
const require = createRequire(import.meta.url)
const sodium =
  require('libsodium-wrappers') as typeof import('libsodium-wrappers')

// 与 Server 协议一致：标准 base64 + 填充（同 server/src/crypto.ts 的 B64）
const B64 = sodium.base64_variants.ORIGINAL
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { WebSocket } from 'ws'
import assert from 'node:assert/strict'
import Database from 'better-sqlite3'
import { pwhashStr } from '../src/crypto.js'

// 所有请求默认带协议版本头（与客户端一致）：服务端对 API 路径做硬校验，
// 缺头/版本不符 → 400 PROTOCOL_VERSION_MISMATCH（PROTOCOL.md §1，2026-09-15 补实现）。
const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': '1', ...(init?.headers as Record<string, string> | undefined) }
  })) as typeof fetch

const ROOT = resolve(import.meta.dirname, '..')
const HELLO = 'hello b, this is a secret message ❤️'

let serverProc: ChildProcess | null = null
let tempDir = ''

// ---------- 工具 ----------

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
      void res // 任何 HTTP 响应都说明 Server 已就绪
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

interface KeyPair {
  privateKey: Uint8Array
  publicKey: Uint8Array
}

/** 消息密文信封（E2EE.md §5.1，字段类型须与 Server 校验一致）。 */
interface MessageEnvelope {
  v: number
  type: string
  key_version: number
  message_id: string
  sender_device_id: string
  nonce: string
  ciphertext: string
}

// ---------- 模拟设备（扮演未来 Dart 客户端） ----------

class TestDevice {
  deviceId = ''
  personId = ''
  keypair: KeyPair
  sessionToken = ''
  spaceKey: Uint8Array
  spaceId = ''
  partnerSlot = -1

  constructor (spaceKey: Uint8Array) {
    this.keypair = sodium.crypto_box_keypair()
    this.spaceKey = spaceKey
  }

  /** 创建空间（v2 入口）：**一步完成设备登记 + 签发绑定该空间的会话**。
   *  替代已删除的 v1 `POST /devices/enroll`（v1 收敛，2026-09-15）。 */
  async createSpace (port: number, personName = '测试空间', partnerName?: string): Promise<string> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        person_name: personName,
        ...(partnerName ? { partner_name: partnerName } : {}),
        public_key: sodium.to_base64(this.keypair.publicKey, B64),
        device_name: 'dev-a'
      })
    })
    assert.equal(res.status, 201, 'create space should succeed')
    const body = (await res.json()) as {
      spaceId: string
      deviceId: string
      creatorPersonId: string
      sessionToken: string
    }
    this.spaceId = body.spaceId
    this.deviceId = body.deviceId
    this.personId = body.creatorPersonId
    this.sessionToken = body.sessionToken
    this.partnerSlot = 0
    return body.spaceId
  }

  /** 生成一次性 join token（需创建者会话）。 */
  async mintJoinToken (port: number): Promise<string> {
    const res = await fetch(
      `http://127.0.0.1:${port}/spaces/${this.spaceId}/join-tokens`,
      { method: 'POST', headers: { Authorization: `Bearer ${this.sessionToken}` } }
    )
    assert.equal(res.status, 201, 'mint join token should succeed')
    return ((await res.json()) as { joinToken: string }).joinToken
  }

  /** 加入空间（v2 入口）：登记设备 + 签发会话 + 返回自己的身份槽位。 */
  async joinSpace (port: number, token: string, partnerSlot = 1): Promise<void> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token,
        public_key: sodium.to_base64(this.keypair.publicKey, B64),
        device_name: 'dev-b',
        partner_slot: partnerSlot
      })
    })
    assert.equal(res.status, 200, 'join space should succeed')
    const body = (await res.json()) as {
      spaceId: string
      personId: string
      partnerSlot: number
      sessionToken: string
      deviceId: string
    }
    this.spaceId = body.spaceId
    this.personId = body.personId
    this.partnerSlot = body.partnerSlot
    this.sessionToken = body.sessionToken
    this.deviceId = body.deviceId
  }

  /** challenge-response 重新认证（已登记设备冷启动路径）。
   *  **challenge 必须带 space_id**（v2：会话绑定空间；不带会拿到无 space 的会话）。 */
  async auth (port: number): Promise<void> {
    const challengeRes = await fetch(
      `http://127.0.0.1:${port}/auth/challenge`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ device_id: this.deviceId, space_id: this.spaceId })
      }
    )
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
    const { session_token } = (await verifyRes.json()) as {
      session_token: string
    }
    this.sessionToken = session_token
  }

  /** 客户端 E2EE 加密（E2EE.md §5）：SpaceKey → MessageKey → XChaCha20-Poly1305。 */
  encryptMessage (
    messageId: string,
    plaintext: string,
    spaceId: string
  ): MessageEnvelope {
    const msgKey = sodium.crypto_generichash(
      32,
      sodium.from_string(`m:${messageId}`),
      this.spaceKey
    )
    const nonce = sodium.randombytes_buf(24)
    const aad = sodium.from_string(
      `einz-v1${spaceId}${messageId}${this.deviceId}text1`
    )
    const ciphertext = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
      sodium.from_string(plaintext),
      aad,
      null,
      nonce,
      msgKey
    )
    return {
      v: 1,
      type: 'text',
      key_version: 1,
      message_id: messageId,
      sender_device_id: this.deviceId,
      nonce: sodium.to_base64(nonce, B64),
      ciphertext: sodium.to_base64(ciphertext, B64)
    }
  }

  /** 客户端 E2EE 解密（验证同步回来的密文可解）。 */
  decryptMessage (env: MessageEnvelope, spaceId: string): string {
    const msgKey = sodium.crypto_generichash(
      32,
      sodium.from_string(`m:${env.message_id}`),
      this.spaceKey
    )
    const nonce = sodium.from_base64(env.nonce, B64)
    const aad = sodium.from_string(
      `einz-v1${spaceId}${env.message_id}${env.sender_device_id}text1`
    )
    const plain = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
      null,
      sodium.from_base64(env.ciphertext, B64),
      aad,
      nonce,
      msgKey
    )
    return sodium.to_string(plain)
  }

  async postMessage (
    port: number,
    env: Record<string, string>
  ): Promise<{ server_sequence: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/messages`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.sessionToken}`
      },
      body: JSON.stringify(env)
    })
    assert.equal(res.status, 200, 'post message should succeed')
    return (await res.json()) as { server_sequence: number }
  }

  async sync (
    port: number,
    after: number
  ): Promise<{ messages: Record<string, string>[]; last_sequence: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/sync?after=${after}`, {
      headers: { Authorization: `Bearer ${this.sessionToken}` }
    })
    assert.equal(res.status, 200, 'sync should succeed')
    return (await res.json()) as {
      messages: Record<string, string>[]
      last_sequence: number
    }
  }
}

// ---------- 主流程 ----------

async function main (): Promise<void> {
  await sodium.ready

  tempDir = mkdtempSync(join(tmpdir(), 'einz-smoke-'))
  const spaceKey = sodium.randombytes_buf(32)
  const devA = new TestDevice(spaceKey)
  const devB = new TestDevice(spaceKey)

  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(tempDir, 'einz.sqlite.db'),
      EINZ_FILES: join(tempDir, 'files'),
      // 取包限速阈值压小，便于本测试快速断言（生产默认 10 次/15 分钟）
      EINZ_ESCROW_RATE_MAX: '2'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  serverProc.stderr?.on('data', d => process.stderr.write(`[server] ${d}`))

  try {
    await waitReady(port)

    // 0) 协议版本硬校验（PROTOCOL.md §1）：缺头 → 400（/health 免校验，见下一段）
    const noVersion = await RAW_FETCH(`http://127.0.0.1:${port}/space`)
    assert.equal(noVersion.status, 400, '缺少 X-Protocol-Version 的请求必须 400')
    const wrongVersion = await RAW_FETCH(`http://127.0.0.1:${port}/space`, {
      headers: { 'X-Protocol-Version': '99' }
    })
    assert.equal(wrongVersion.status, 400, '协议版本不符必须 400')
    const healthNoVersion = await RAW_FETCH(`http://127.0.0.1:${port}/health`)
    assert.equal(healthNoVersion.status, 200, '/health 免协议版本校验（监控/curl 用）')

    // 1) 未登记设备挑战 → 403（带了 space_id 仍应拒绝：设备不在 devices 表）
    const evil = await fetch(`http://127.0.0.1:${port}/auth/challenge`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: 'dev-evil', space_id: 'space-evil' })
    })
    assert.equal(evil.status, 403, 'non-enrolled device must be rejected')

    // 2) A 创建空间（v2 入口：登记设备 + 签发会话）
    const spaceId = await devA.createSpace(port)

    // 2b) 已登记设备但不带 space_id → 400（v1 收敛：会话必须绑定空间；
    //     顺序上设备校验在前，所以这条要用**已登记**的设备验）
    const noSpace = await fetch(`http://127.0.0.1:${port}/auth/challenge`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: devA.deviceId })
    })
    assert.equal(noSpace.status, 400, 'challenge without space_id must be rejected')

    // 3) A 重新认证（冷启动路径：challenge 带 space_id）
    await devA.auth(port)

    // 4) A 加密发送
    const envA = devA.encryptMessage('msg-0001', HELLO, spaceId)
    const posted = await devA.postMessage(port, envA)
    assert.equal(posted.server_sequence, 1, 'first message gets sequence 1')

    // 5) 幂等：同 message_id 重复上传 → 不新增
    const repost = await devA.postMessage(port, envA)
    assert.equal(
      repost.server_sequence,
      1,
      'duplicate message_id is idempotent'
    )

    // 5.1) 非法 message_id（含路径字符）必须 400——P1 路径遍历防御：
    //      message_id 会被客户端当文件路径片段（App 媒体解密缓存按它拼文件名），
    //      此前 messages 端点只查了"非空字符串"（老板 2026-09-14 排查出的缺口）
    for (const badId of ['a/../../evil', '..\\evil', 'a.b', 'a'.repeat(65)]) {
      const bad = await fetch(`http://127.0.0.1:${port}/messages`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${devA.sessionToken}`
        },
        body: JSON.stringify({ ...envA, message_id: badId })
      })
      assert.equal(
        bad.status,
        400,
        `illegal message_id ${JSON.stringify(badId)} must be rejected`
      )
    }

    // 6) B 用 join token 加入空间 + 认证 + 增量同步（v2 入口，替代 v1 邀请码登记）
    const joinToken = await devA.mintJoinToken(port)
    await devB.joinSpace(port, joinToken)
    await devB.auth(port)
    const sync1 = await devB.sync(port, 0)
    assert.equal(sync1.messages.length, 1, 'B should receive exactly 1 message')
    assert.equal(sync1.messages[0].message_id, 'msg-0001')

    // 6) 关键断言：Server 同步返回的是密文，明文绝不出现
    const raw = JSON.stringify(sync1)
    assert.ok(
      !raw.includes(HELLO),
      'plaintext must NOT appear in sync response'
    )

    // 7) B 解密成功（端到端闭环）
    const decrypted = devB.decryptMessage(sync1.messages[0], spaceId)
    assert.equal(decrypted, HELLO, 'B must decrypt the message correctly')

    // 8) 数据库核查：messages 表只有密文，无明文
    const db = new Database(join(tempDir, 'einz.sqlite.db'), { readonly: true })
    const row = db
      .prepare(`SELECT ciphertext FROM messages WHERE message_id = 'msg-0001'`)
      .get() as { ciphertext: string }
    assert.ok(row.ciphertext.length > 0, 'ciphertext stored')
    assert.ok(!row.ciphertext.includes(HELLO), 'DB must not contain plaintext')
    db.close()

    // 9) 无 token 访问 → 401
    const noAuth = await fetch(`http://127.0.0.1:${port}/sync?after=0`)
    assert.equal(noAuth.status, 401, 'missing token must be rejected')

    // 10) WS：A 连接后，B 发消息 → A 实时收到 message.new
    await new Promise<void>((done, fail) => {
      // 凭证走握手头（PROTOCOL.md §8.1：token 不放 URL query）
      const ws = new WebSocket(
        `ws://127.0.0.1:${port}/ws?pv=1`,
        { headers: { Authorization: `Bearer ${devA.sessionToken}` } }
      )
      const timer = setTimeout(
        () => fail(new Error('WS message.new timeout')),
        5000
      )
      ws.on('message', data => {
        const frame = JSON.parse(data.toString())
        if (frame.type === 'hello') {
          void devB.postMessage(
            port,
            devB.encryptMessage('msg-0002', 'reply from b', spaceId)
          )
        } else if (frame.type === 'message.new') {
          assert.equal(
            frame.payload.message.message_id,
            'msg-0002',
            "A should receive B's message in realtime"
          )
          clearTimeout(timer)
          ws.close()
          done()
        }
      })
      ws.on('error', e => fail(e))
    })

    // 11) 密钥托管（口令托管，KEY_ESCROW.md §4）：A 上传 → B 拉取一致 →
    //     坏字段 400 / 无 token 401 → 数据库只存原样密文包 → DELETE 清空
    const escrowPkg = {
      format: 'backup-v1',
      salt: sodium.to_base64(sodium.randombytes_buf(16), B64),
      nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
      ciphertext: sodium.to_base64(sodium.randombytes_buf(48), B64)
    }
    const escrowUp = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${devA.sessionToken}`
      },
      body: JSON.stringify({ package: escrowPkg })
    })
    assert.equal(escrowUp.status, 200, 'escrow upload should succeed')

    const escrowGet = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      headers: { Authorization: `Bearer ${devB.sessionToken}` }
    })
    assert.equal(escrowGet.status, 200, 'whitelisted peer should fetch escrow')
    const escrowBody = (await escrowGet.json()) as { package: typeof escrowPkg }
    assert.equal(
      escrowBody.package.ciphertext,
      escrowPkg.ciphertext,
      'B should fetch the same escrow package'
    )

    const escrowBad = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${devA.sessionToken}`
      },
      body: JSON.stringify({ package: { format: 'x', salt: 'y', nonce: 'z' } })
    })
    assert.equal(
      escrowBad.status,
      400,
      'malformed escrow package must be rejected'
    )

    const escrowNoAuth = await fetch(`http://127.0.0.1:${port}/key-escrow`)
    assert.equal(escrowNoAuth.status, 401, 'missing token must be rejected')

    const escrowDb = new Database(join(tempDir, 'einz.sqlite.db'), {
      readonly: true
    })
    const escrowRow = escrowDb
      .prepare(`SELECT package FROM key_escrow`)
      .get() as { package: string }
    assert.ok(
      escrowRow.package.includes(escrowPkg.ciphertext),
      'package stored verbatim (server must not parse content)'
    )
    escrowDb.close()

    const escrowDel = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${devA.sessionToken}` }
    })
    assert.equal(escrowDel.status, 200, 'escrow delete should succeed')
    const escrowAfter = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      headers: { Authorization: `Bearer ${devA.sessionToken}` }
    })
    assert.deepEqual(
      await escrowAfter.json(),
      {},
      'escrow cleared after delete'
    )

    // 12) 名称表（v2）：创建空间时带 partner_name → 落 space_members.display_name，
    //     GET /space 的 person_names 应含双方名字。**名称的唯一数据源是
    //     space_members**——v1 的 meta `person_name:*` 表已随收敛删除，所以这里
    //     按 v2 的读法断言（此前两个用例查 meta，已作废）。
    const preset = new TestDevice(sodium.randombytes_buf(32))
    await preset.createSpace(port, '我', 'Alice')
    const infoRes = await fetch(`http://127.0.0.1:${port}/space`, {
      headers: { Authorization: `Bearer ${preset.sessionToken}` }
    })
    assert.equal(infoRes.status, 200, 'GET /space should succeed')
    const info = (await infoRes.json()) as {
      person_names: Record<string, string>
    }
    assert.equal(
      info.person_names[preset.personId],
      '我',
      '创建者名字应落 space_members.display_name'
    )
    // partner 预置名落在 space_members 的 slot=1 行（该行 person_id 仍为 NULL，
    // 等伴侣加入后才出现在 /space 的 person_names —— 这是"预置"语义，不是丢数据）
    const dbPreset = new Database(join(tempDir, 'einz.sqlite.db'), { readonly: true })
    const partnerRow = dbPreset
      .prepare(`SELECT display_name FROM space_members WHERE space_id = ? AND partner_slot = 1`)
      .get(preset.spaceId) as { display_name: string | null } | undefined
    dbPreset.close()
    assert.equal(
      partnerRow?.display_name,
      'Alice',
      'partner_name 预置应落 space_members slot=1（后续设备引导可按名字选身份）'
    )

    // 12b) 改名后名称表即时更新（回归：90ec740 把 getSpace 改读 space_members，
    //      但 updatePersonName 仍只写 meta → GET /space 返回旧名——TUI 右上角自己
    //      的名字不刷新、对方改名后我方名称表被旧值覆盖）。验证：创建空间 →
    //      GET /space 旧名 → 改名 → GET /space 新名。
    const tempDir4 = mkdtempSync(join(tmpdir(), 'einz-rename-'))
    const port4 = await freePort()
    let serverProc4: ChildProcess | null = null
    try {
      serverProc4 = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
        env: {
          ...process.env,
          PORT: String(port4),
          EINZ_DB: join(tempDir4, 'einz.sqlite.db'),
          EINZ_FILES: join(tempDir4, 'files')
        },
        stdio: ['ignore', 'pipe', 'pipe']
      })
      serverProc4.stderr?.on('data', d =>
        process.stderr.write(`[server4] ${d}`)
      )
      await waitReady(port4)

      const creatorPk = sodium.to_base64(sodium.randombytes_buf(32), B64)
      const create = await fetch(`http://127.0.0.1:${port4}/spaces`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          person_name: 'luk',
          public_key: creatorPk,
          device_name: 'dev-a'
        })
      })
      assert.equal(create.status, 201, 'create space should succeed')
      const created = (await create.json()) as {
        spaceId: string
        creatorPersonId: string
        sessionToken: string
      }

      const before = await fetch(`http://127.0.0.1:${port4}/space`, {
        headers: { Authorization: `Bearer ${created.sessionToken}` }
      })
      assert.equal(before.status, 200, 'get space should succeed')
      const beforeBody = (await before.json()) as {
        person_names: Record<string, string>
      }
      assert.equal(
        beforeBody.person_names[created.creatorPersonId],
        'luk',
        'create 后名称表应为创建名'
      )

      // /myname 改名 → GET /space 必须返回新名（meta 与 space_members 同步）
      const rename = await fetch(
        `http://127.0.0.1:${port4}/devices/person-name`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${created.sessionToken}`
          },
          body: JSON.stringify({ person_name: 'lukas' })
        }
      )
      assert.equal(rename.status, 200, 'rename should succeed')
      const after = await fetch(`http://127.0.0.1:${port4}/space`, {
        headers: { Authorization: `Bearer ${created.sessionToken}` }
      })
      const afterBody = (await after.json()) as {
        person_names: Record<string, string>
      }
      assert.equal(
        afterBody.person_names[created.creatorPersonId],
        'lukas',
        '改名后 GET /space 名称表应即时反映新名'
      )
    } finally {
      await new Promise<void>(done => {
        if (!serverProc4 || serverProc4.exitCode !== null) {
          done()
          return
        }
        const timer = setTimeout(() => {
          serverProc4?.kill('SIGKILL')
          done()
        }, 3000)
        serverProc4.once('exit', () => {
          clearTimeout(timer)
          done()
        })
      })
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          rmSync(tempDir4, { recursive: true, force: true })
          break
        } catch {
          await new Promise(r => setTimeout(r, 200))
        }
      }
    }

    // 12c) 两阶段附件上传回归（PROTOCOL.md §6.1：先传 blob 后发消息）——
    //      v2 移除全局 space_id 后 storeAttachment 一度改从 messages 反查归属
    //      空间，但传 blob 时消息尚未入库 → NULL 落入 attachments.space_id
    //      (NOT NULL) → 500 → 发送端气泡回退「📎 文件名」、接收端 /sync 拿不到
    //      attachments_meta（CLI /open 报「附件元数据尚未就绪」）。
    //      验证：blob 200 → 消息入库 → /sync 返回元数据 → 下载字节一致。
    const tempDir5 = mkdtempSync(join(tmpdir(), 'einz-attach-'))
    const port5 = await freePort()
    let serverProc5: ChildProcess | null = null
    try {
      serverProc5 = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
        env: {
          ...process.env,
          PORT: String(port5),
          EINZ_DB: join(tempDir5, 'einz.sqlite.db'),
          EINZ_FILES: join(tempDir5, 'files')
        },
        stdio: ['ignore', 'pipe', 'pipe']
      })
      serverProc5.stderr?.on('data', d =>
        process.stderr.write(`[server5] ${d}`)
      )
      await waitReady(port5)

      const creatorPk5 = sodium.to_base64(sodium.randombytes_buf(32), B64)
      const create5 = await fetch(`http://127.0.0.1:${port5}/spaces`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          person_name: 'luk',
          public_key: creatorPk5,
          device_name: 'dev-a'
        })
      })
      assert.equal(create5.status, 201, 'create space should succeed')
      const created5 = (await create5.json()) as {
        spaceId: string
        deviceId: string
        sessionToken: string
      }
      const auth5 = { Authorization: `Bearer ${created5.sessionToken}` }

      const blob = Buffer.from('einz two-phase attachment payload ❤️')
      const messageId5 = '01a0ffff-aaaa-7bbb-9ccc-0123456789ab'
      const attachmentId5 = '01a0ffff-bbbb-7ccc-9ddd-0123456789ab'
      const up5 = await fetch(`http://127.0.0.1:${port5}/attachments`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
          Authorization: `Bearer ${created5.sessionToken}`,
          'x-attachment-meta': JSON.stringify({
            message_id: messageId5,
            attachment_id: attachmentId5,
            key_version: 1,
            size: blob.length,
            sha256: createHash('sha256').update(blob).digest('base64'),
            nonce: sodium.to_base64(sodium.randombytes_buf(24), B64)
          })
        },
        body: blob
      })
      assert.equal(
        up5.status,
        200,
        'two-phase upload (blob before message) must succeed'
      )

      const msg5 = await fetch(`http://127.0.0.1:${port5}/messages`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${created5.sessionToken}`
        },
        body: JSON.stringify({
          v: 1,
          type: 'image',
          key_version: 1,
          message_id: messageId5,
          sender_device_id: created5.deviceId,
          nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
          ciphertext: sodium.to_base64(sodium.randombytes_buf(32), B64)
        })
      })
      assert.equal(msg5.status, 200, 'post image message should succeed')

      const sync5 = await fetch(`http://127.0.0.1:${port5}/sync?after=0`, {
        headers: auth5
      })
      const syncBody5 = (await sync5.json()) as {
        attachments_meta: { attachment_id: string; message_id: string }[]
      }
      assert.ok(
        syncBody5.attachments_meta.some(
          a =>
            a.attachment_id === attachmentId5 && a.message_id === messageId5
        ),
        '/sync must return attachments_meta so peers can download'
      )

      const dl5 = await fetch(
        `http://127.0.0.1:${port5}/attachments/${attachmentId5}`,
        { headers: auth5 }
      )
      assert.equal(dl5.status, 200, 'attachment download should succeed')
      assert.deepEqual(
        Buffer.from(await dl5.arrayBuffer()),
        blob,
        'downloaded blob must match uploaded bytes'
      )
    } finally {
      await new Promise<void>(done => {
        if (!serverProc5 || serverProc5.exitCode !== null) {
          done()
          return
        }
        const timer = setTimeout(() => {
          serverProc5?.kill('SIGKILL')
          done()
        }, 3000)
        serverProc5.once('exit', () => {
          clearTimeout(timer)
          done()
        })
      })
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          rmSync(tempDir5, { recursive: true, force: true })
          break
        } catch {
          await new Promise(r => setTimeout(r, 200))
        }
      }
    }

    // 12d) 改名广播不得依赖发起方 WS 在线（回归：broadcastProfileUpdated 此前用
    //      sameSpace(发起方) —— 只认发起方的在线连接，移动端切后台/断线就一条
    //      都不发 → 对端（TUI）一直显示旧名字，只有对方自己改名才纠正）。
    //      验证：B 连 WS 在线，A **不连 WS** 改名 → B 仍收到 profile.updated。
    const tempDir6 = mkdtempSync(join(tmpdir(), 'einz-profile-bc-'))
    const port6 = await freePort()
    let serverProc6: ChildProcess | null = null
    try {
      serverProc6 = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
        env: {
          ...process.env,
          PORT: String(port6),
          EINZ_DB: join(tempDir6, 'einz.sqlite.db'),
          EINZ_FILES: join(tempDir6, 'files')
        },
        stdio: ['ignore', 'pipe', 'pipe']
      })
      serverProc6.stderr?.on('data', d =>
        process.stderr.write(`[server6] ${d}`)
      )
      await waitReady(port6)

      const create6 = await fetch(`http://127.0.0.1:${port6}/spaces`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          person_name: 'alice',
          public_key: sodium.to_base64(sodium.randombytes_buf(32), B64),
          device_name: 'dev-a'
        })
      })
      assert.equal(create6.status, 201, 'create space should succeed')
      const a6 = (await create6.json()) as {
        spaceId: string
        creatorPersonId: string
        sessionToken: string
      }
      const tk6 = await fetch(
        `http://127.0.0.1:${port6}/spaces/${a6.spaceId}/join-tokens`,
        {
          method: 'POST',
          // C1 修复后：签发邀请需要该空间成员会话（创建者自己即可）
          headers: { Authorization: `Bearer ${a6.sessionToken}` }
        }
      )
      assert.equal(tk6.status, 201, 'create join token should succeed')
      const { joinToken } = (await tk6.json()) as { joinToken: string }
      const join6 = await fetch(`http://127.0.0.1:${port6}/spaces/join`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: joinToken,
          public_key: sodium.to_base64(sodium.randombytes_buf(32), B64),
          device_name: 'dev-b'
        })
      })
      assert.equal(join6.status, 200, 'join should succeed')
      const b6 = (await join6.json()) as { sessionToken: string }

      // B 在线（WS）；A 始终不连 WS
      const ws6 = new WebSocket(
        `ws://127.0.0.1:${port6}/ws?pv=1`,
        { headers: { Authorization: `Bearer ${b6.sessionToken}` } }
      )
      const got = new Promise<Record<string, string>>((done, fail) => {
        const timer = setTimeout(
          () => fail(new Error('profile.updated not received')),
          8000
        )
        ws6.on('message', data => {
          const frame = JSON.parse(data.toString()) as {
            type: string
            payload?: Record<string, string>
          }
          if (frame.type === 'profile.updated') {
            clearTimeout(timer)
            done(frame.payload ?? {})
          }
        })
        ws6.on('error', e => {
          clearTimeout(timer)
          fail(e)
        })
      })
      await new Promise<void>(done => ws6.on('open', () => done()))

      const rename6 = await fetch(
        `http://127.0.0.1:${port6}/devices/person-name`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${a6.sessionToken}`
          },
          body: JSON.stringify({ person_name: 'alice-new' })
        }
      )
      assert.equal(rename6.status, 200, 'rename should succeed')

      const payload6 = await got
      assert.equal(
        payload6.person_id,
        a6.creatorPersonId,
        'broadcast must carry the renamed person_id'
      )
      assert.equal(
        payload6.person_name,
        'alice-new',
        'broadcast must carry the new person_name'
      )
      ws6.close()
    } finally {
      await new Promise<void>(done => {
        if (!serverProc6 || serverProc6.exitCode !== null) {
          done()
          return
        }
        const timer = setTimeout(() => {
          serverProc6?.kill('SIGKILL')
          done()
        }, 3000)
        serverProc6.once('exit', () => {
          clearTimeout(timer)
          done()
        })
      })
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          rmSync(tempDir6, { recursive: true, force: true })
          break
        } catch {
          await new Promise(r => setTimeout(r, 200))
        }
      }
    }

    // 12) 口令托管：上传带口令哈希的密文包，并确认 v1 的 /recover 已整体移除
    //     （passphrase_hash 现在只用于"加入方取包时校验口令"，见 escrowForSpace）
    const escrowPass = 'recover-pass-123'
    const escrowHash = await pwhashStr(escrowPass)
    const escrowRec = await fetch(`http://127.0.0.1:${port}/key-escrow`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${devA.sessionToken}`
      },
      body: JSON.stringify({ package: escrowPkg, passphrase_hash: escrowHash })
    })
    assert.equal(
      escrowRec.status,
      200,
      'escrow upload with passphrase_hash should succeed'
    )
    const recoverGone = await fetch(`http://127.0.0.1:${port}/recover`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ passphrase: escrowPass })
    })
    assert.equal(
      recoverGone.status,
      404,
      '/recover（全丢恢复）应已移除——该功能在 v2 无意义（见 docs/PROTOCOL.md）'
    )

    // 13) 取包端点限速（2026-09-14）：`POST /spaces/{id}/key-escrow` 是**免设备认证**的
    //     口令校验端点，若不限速即可在线爆破口令（口令 = 拿到 Space Key 的凭证）。
    //     阈值由 EINZ_ESCROW_RATE_MAX 压到 2：两次失败后第 3 次起 429。
    //     注（2026-09-15 C1）：取包分支仍免认证，但**上传分支要成员会话**——所以
    //     这里建空间时带上 public_key，拿创建者自己的 session 用于上传。
    const rateSpace = await (async () => {
      const r = await fetch(`http://127.0.0.1:${port}/spaces`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          person_name: '限速测试空间',
          public_key: sodium.to_base64(sodium.randombytes_buf(32), B64),
          device_name: 'dev-rate'
        })
      })
      assert.equal(r.status, 201, 'create space for rate-limit test should succeed')
      return (await r.json()) as { spaceId: string; sessionToken: string }
    })()
    const ratePkg = {
      format: 'backup-v1',
      salt: sodium.to_base64(sodium.randombytes_buf(16), B64),
      nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
      ciphertext: sodium.to_base64(sodium.randombytes_buf(48), B64)
    }
    const ratePass = 'rate-limit-pass-123'
    const rateUp = await fetch(
      `http://127.0.0.1:${port}/spaces/${rateSpace.spaceId}/key-escrow`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${rateSpace.sessionToken}`
        },
        body: JSON.stringify({
          package: ratePkg,
          passphrase_hash: await pwhashStr(ratePass)
        })
      }
    )
    assert.equal(rateUp.status, 200, 'space escrow upload with hash should succeed')

    // 上传分支必须持成员会话：不带凭证 → 401，非成员 → 403（C1 回归）
    const noAuthUp = await fetch(
      `http://127.0.0.1:${port}/spaces/${rateSpace.spaceId}/key-escrow`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ package: ratePkg, passphrase_hash: await pwhashStr(ratePass) })
      }
    )
    assert.equal(noAuthUp.status, 401, 'escrow upload without session must be rejected')

    const tryPassphrase = async (passphrase: string): Promise<number> => {
      const r = await fetch(
        `http://127.0.0.1:${port}/spaces/${rateSpace.spaceId}/key-escrow`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ passphrase })
        }
      )
      return r.status
    }
    assert.equal(await tryPassphrase(ratePass), 200, 'correct passphrase should fetch the package')
    assert.equal(await tryPassphrase('wrong-1'), 401, 'wrong passphrase must be rejected')
    assert.equal(await tryPassphrase('wrong-2'), 401, 'wrong passphrase must be rejected')
    assert.equal(
      await tryPassphrase('wrong-3'),
      429,
      'exceeding the failure budget must be rate limited (ESCROW_RATE_LIMITED)'
    )
    console.log('✅ 取包限速：2 次失败后第 3 次 429（免认证端点防在线爆破）')

    console.log(
      '✅ 冒烟测试全部通过：建空间+加入 / 认证 / E2EE 密文 / 幂等 / 同步 / 未登记拒绝 / 明文隔离 / WS 实时 / 密钥托管 / 取包限速 / 名称表(space_members)'
    )
  } finally {
    // Windows 上 SIGTERM 后子进程退出是异步的，必须先等它真正退出，
    // 否则 einz.sqlite.db 句柄未释放，rmSync 会报 EBUSY。
    await new Promise<void>(done => {
      if (!serverProc || serverProc.exitCode !== null) {
        done()
        return
      }
      const timer = setTimeout(() => {
        serverProc?.kill('SIGKILL')
        done()
      }, 3000)
      serverProc.once('exit', () => {
        clearTimeout(timer)
        done()
      })
    })
    // 兜底：句柄释放延迟时重试清理
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        rmSync(tempDir, { recursive: true, force: true })
        break
      } catch {
        await new Promise(r => setTimeout(r, 200))
      }
    }
  }
}

main().catch(err => {
  console.error('❌ 冒烟测试失败:', err)
  process.exit(1)
})
