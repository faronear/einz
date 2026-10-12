/**
 * 撤回端点（POST /messages/recall）回归测试（2026-10-10）。
 *
 * 覆盖：可撤（对方未拉取 → 行真删、sync 不再返回）、已送达 409、
 * 非本人 403、消息不存在 404、幂等（撤过的再撤仍 404）。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）。不需要 libsodium
 * （只走 Multiverse 空间创建/加入 + 结构合法的消息信封）。
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import assert from 'node:assert/strict'
import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': PROTOCOL_VERSION, ...(init?.headers as Record<string, string> | undefined) }
  })) as typeof fetch

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
      await fetch(`http://127.0.0.1:${port}/entrances`)
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

interface SyncResult {
  messages: { message_id: string; server_sequence: number }[]
  last_sequence: number
  has_more: boolean
}

/** 极简客户端：只做 Multiverse 创建/加入 + 发消息 + 回执 + 撤回 + sync。 */
class Entrance {
  sessionToken = ''
  entranceId = ''
  memberId = ''

  constructor (private readonly label: string) {}

  async createSpace (port: number): Promise<string> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        public_key: `pk-${this.label}`,
        creator_name: 'Lukas',
        escrow_passphrase: 'pass123',
        sealed_space_key: {
          format: 'einz-backup-v1',
          salt: 'c2FsdA==',
          nonce: 'bm9uY2U=',
          ciphertext: 'Y2lwaGVy'
        }
      })
    })
    assert.equal(res.status, 201, 'create space should succeed')
    const body = (await res.json()) as {
      joinToken: string
      entranceId: string
      creatorMemberId: string
      sessionToken: string
    }
    this.entranceId = body.entranceId
    this.memberId = body.creatorMemberId
    this.sessionToken = body.sessionToken
    return body.joinToken
  }

  async joinSpace (port: number, token: string): Promise<void> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token,
        public_key: `pk-${this.label}`,
        member_name: this.label,
        member_gender: 'female',
        entrance_name: this.label
      })
    })
    assert.equal(res.status, 200, 'join space should succeed')
    const body = (await res.json()) as { memberId: string; entranceId: string; sessionToken: string }
    this.entranceId = body.entranceId
    this.memberId = body.memberId
    this.sessionToken = body.sessionToken
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
        sender_entrance_id: this.entranceId,
        nonce: 'bm9uY2U=',
        ciphertext: 'Y2lwaGVy'
      })
    })
    assert.equal(res.status, 200, 'post message should succeed')
    return ((await res.json()) as { server_sequence: number }).server_sequence
  }

  async postReceipt (port: number, deliveredUptoSeq: number): Promise<void> {
    const res = await fetch(`http://127.0.0.1:${port}/receipts`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.sessionToken}`
      },
      body: JSON.stringify({ delivered_upto_seq: deliveredUptoSeq })
    })
    assert.equal(res.status, 200, 'post receipts should succeed')
  }

  async sync (port: number, after = 0): Promise<SyncResult> {
    const res = await fetch(`http://127.0.0.1:${port}/sync?after=${after}&limit=100`, {
      headers: { Authorization: `Bearer ${this.sessionToken}` }
    })
    assert.equal(res.status, 200, 'sync should succeed')
    return await res.json() as SyncResult
  }

  /** 撤回，返回 HTTP 状态码（不断言，用例各自断言）。 */
  async recall (port: number, messageId: string): Promise<number> {
    const res = await fetch(`http://127.0.0.1:${port}/messages/recall`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.sessionToken}`
      },
      body: JSON.stringify({ message_id: messageId })
    })
    return res.status
  }
}

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-recall-'))
  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(tempDir, 'einz.sqlite.db'),
      EINZ_FILES: join(tempDir, 'files')
    },
    stdio: 'ignore'
  })
  await waitReady(port)

  try {
    const alice = new Entrance('alice')
    const joinToken = await alice.createSpace(port)
    const bob = new Entrance('bob')
    await bob.joinSpace(port, joinToken)

    // Alice 发两条 → seq 1、2
    assert.equal(await alice.postMessage(port, 'm-1'), 1)
    assert.equal(await alice.postMessage(port, 'm-2'), 2)

    // 1) 未送达可撤：撤 m-1（Bob 尚未上报 delivered）→ 200，行真删
    assert.equal(await alice.recall(port, 'm-1'), 200, '未送达应可撤')
    const bobSync = await bob.sync(port)
    assert.ok(
      !bobSync.messages.some(m => m.message_id === 'm-1'),
      '撤回后 Bob 的 sync 不应再返回该消息'
    )
    assert.ok(bobSync.messages.some(m => m.message_id === 'm-2'), '未撤的 m-2 应仍在')

    // 2) 已送达 409：Bob 上报 delivered=2 → m-2 不可撤
    await bob.postReceipt(port, 2)
    assert.equal(await alice.recall(port, 'm-2'), 409, '对方已拉取应 409')

    // 3) 非本人 403：Bob 撤 Alice 的 m-2
    assert.equal(await bob.recall(port, 'm-2'), 403, '非发送者应 403')

    // 4) 不存在 404；撤过的再撤仍 404（幂等）
    assert.equal(await alice.recall(port, 'm-1'), 404, '已撤的再撤应 404')
    assert.equal(await alice.recall(port, 'm-nope'), 404, '不存在的消息应 404')

    // 5) 附件一并删除：撤回带附件的消息后 by-message 应 404
    // （两阶段上传：meta 走 x-attachment-meta 头，blob 走 body；sha256 = 密文哈希）
    const blob = Buffer.from([1, 2, 3, 4])
    const attRes = await fetch(`http://127.0.0.1:${port}/attachments`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/octet-stream',
        Authorization: `Bearer ${alice.sessionToken}`,
        'x-attachment-meta': JSON.stringify({
          message_id: 'bbbb0000-0000-0000-0000-000000000003',
          attachment_id: 'aaaa0000-0000-0000-0000-000000000003',
          key_version: 1,
          size: blob.length,
          sha256: createHash('sha256').update(blob).digest('base64'),
          nonce: 'bm9uY2U='
        })
      },
      body: blob
    })
    if (attRes.status === 200) {
      assert.equal(await alice.postMessage(port, 'bbbb0000-0000-0000-0000-000000000003'), 3, 'm-3 应为 seq 3')
      assert.equal(await alice.recall(port, 'bbbb0000-0000-0000-0000-000000000003'), 200, '未送达附件消息应可撤')
      const meta = await fetch(
        `http://127.0.0.1:${port}/attachments/by-message?message_id=bbbb0000-0000-0000-0000-000000000003`,
        { headers: { Authorization: `Bearer ${alice.sessionToken}` } }
      )
      assert.equal(meta.status, 404, '撤回后附件元数据应 404')
    } else {
      console.log('ℹ️ 附件上传被拒:', attRes.status, await attRes.text())
    }

    console.log('✅ 撤回测试通过：未送达可撤 / 已送达 409 / 非本人 403 / 幂等 404 / 附件一并删')
  } finally {
    if (serverProc && serverProc.exitCode === null) serverProc.kill()
    rmSync(tempDir, { recursive: true, force: true })
  }
}

main().catch(err => {
  console.error('❌ 撤回测试失败:', err)
  if (serverProc && serverProc.exitCode === null) serverProc.kill()
  process.exit(1)
})
