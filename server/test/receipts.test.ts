/**
 * 消息回执（已送达/已读）回归测试。
 *
 * 模型：按 (space, partner) 存单调高水位（HWM）——
 *   我的消息 seq=S 已送达 ⟺ 对方 delivered_upto_seq ≥ S；已读 ⟺ read_upto_seq ≥ S。
 * 本测试覆盖：单调只前进、夹紧到真实 max seq、读隐含送达、GET 回读、WS 广播。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）。本测试不需要 libsodium
 * （只走 Multiverse 空间创建/加入 + 结构合法的消息信封）。
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { WebSocket } from 'ws'
import assert from 'node:assert/strict'

// 所有请求默认带协议版本头（与客户端一致）：服务端对 API 路径做硬校验，
// 缺头/版本不符 → 400 PROTOCOL_VERSION_MISMATCH（PROTOCOL.md §1，2026-09-15 补实现）。
const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': '1', ...(init?.headers as Record<string, string> | undefined) }
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
      const res = await fetch(`http://127.0.0.1:${port}/entrances`)
      void res
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

interface ReceiptRow {
  partner_id: string
  delivered_upto_seq: number
  read_upto_seq: number
  updated_at: number
}

/** 极简客户端：只做 Multiverse 创建/加入 + 发消息 + 回执。 */
class Entrance {
  sessionToken = ''
  entranceId = ''
  partnerId = ''

  constructor (private readonly label: string) {}

  async createSpace (port: number): Promise<string> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        public_key: `pk-${this.label}`,
        creator_name: 'Lukas',
        peer_name: 'Alice',
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
      spaceId: string
      joinToken: string
      entranceId: string
      creatorPartnerId: string
      sessionToken: string
    }
    this.entranceId = body.entranceId
    this.partnerId = body.creatorPartnerId
    this.sessionToken = body.sessionToken
    return body.joinToken
  }

  async joinSpace (port: number, token: string): Promise<string> {
    const res = await fetch(`http://127.0.0.1:${port}/spaces/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token,
        public_key: `pk-${this.label}`,
        slot: 1,
        entrance_name: this.label
      })
    })
    assert.equal(res.status, 200, 'join space should succeed')
    const body = (await res.json()) as {
      spaceId: string
      partnerId: string
      entranceId: string
      sessionToken: string
    }
    this.entranceId = body.entranceId
    this.partnerId = body.partnerId
    this.sessionToken = body.sessionToken
    return body.spaceId
  }

  /** 发一条结构合法的消息，返回 server_sequence。 */
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

  async postReceipt (
    port: number,
    body: { delivered_upto_seq?: number; read_upto_seq?: number }
  ): Promise<{ delivered_upto_seq: number; read_upto_seq: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/receipts`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.sessionToken}`
      },
      body: JSON.stringify(body)
    })
    assert.equal(res.status, 200, 'post receipts should succeed')
    return (await res.json()) as {
      delivered_upto_seq: number
      read_upto_seq: number
    }
  }

  async getReceipts (port: number): Promise<ReceiptRow[]> {
    const res = await fetch(`http://127.0.0.1:${port}/receipts`, {
      headers: { Authorization: `Bearer ${this.sessionToken}` }
    })
    assert.equal(res.status, 200, 'get receipts should succeed')
    return ((await res.json()) as { receipts: ReceiptRow[] }).receipts
  }
}

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-receipts-'))
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

    // 1) Bob 上报 delivered=1 → read 仍 0
    let cur = await bob.postReceipt(port, { delivered_upto_seq: 1 })
    assert.deepEqual(cur, { delivered_upto_seq: 1, read_upto_seq: 0 }, 'delivered=1, read=0')

    // 2) 读隐含送达：只上报 read=1 → delivered 也应 ≥ 1
    cur = await bob.postReceipt(port, { read_upto_seq: 1 })
    assert.deepEqual(cur, { delivered_upto_seq: 1, read_upto_seq: 1 },
      '读隐含送达：delivered 应被抬到 ≥ read')

    // 3) 单调只前进：回退值被忽略
    cur = await bob.postReceipt(port, { delivered_upto_seq: 0, read_upto_seq: 0 })
    assert.deepEqual(cur, { delivered_upto_seq: 1, read_upto_seq: 1 },
      '单调只前进：回退上报应被忽略')

    // 4) 夹紧到真实 max seq：999 → 2
    cur = await bob.postReceipt(port, { delivered_upto_seq: 999 })
    assert.deepEqual(cur, { delivered_upto_seq: 2, read_upto_seq: 1 },
      'delivered 应夹紧到本 space 的 max seq(=2)，read 不受影响')

    // 5) Alice 侧 GET /receipts 看到 Bob 的行（自己没报过 → 只有 Bob 一行）
    const rows = await alice.getReceipts(port)
    assert.equal(rows.length, 1, 'Alice 侧应只看到 Bob 的一条回执行')
    assert.equal(rows[0].partner_id, bob.partnerId, 'partner_id 应为 Bob')
    assert.equal(rows[0].delivered_upto_seq, 2)
    assert.equal(rows[0].read_upto_seq, 1)

    // 6) 非法入参 400
    const bad = await fetch(`http://127.0.0.1:${port}/receipts`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${bob.sessionToken}`
      },
      body: JSON.stringify({ delivered_upto_seq: -1 })
    })
    assert.equal(bad.status, 400, '负数应被拒')

    // 7) Alice 在线时，Bob 上报 read=2 → Alice 应通过 WS 收到 receipt.updated
    await new Promise<void>((done, fail) => {
      const ws = new WebSocket(
        `ws://127.0.0.1:${port}/ws?pv=1`,
        { headers: { Authorization: `Bearer ${alice.sessionToken}` } }
      )
      const timer = setTimeout(() => fail(new Error('WS receipt.updated timeout')), 5000)
      ws.on('message', data => {
        const frame = JSON.parse(data.toString())
        if (frame.type === 'hello') {
          void bob.postReceipt(port, { read_upto_seq: 2 })
        } else if (frame.type === 'receipt.updated') {
          assert.equal(frame.payload.partner_id, bob.partnerId, 'payload.partner_id 应为 Bob')
          assert.equal(frame.payload.read_upto_seq, 2, 'payload.read_upto_seq 应为 2')
          assert.equal(frame.payload.delivered_upto_seq, 2, '读隐含送达 → delivered 应为 2')
          clearTimeout(timer)
          ws.close()
          done()
        }
      })
      ws.on('error', e => fail(e))
    })

    console.log('✅ 回执测试通过：单调高水位 / 夹紧 max seq / 读隐含送达 / GET 回读 / WS 广播')
  } finally {
    if (serverProc && serverProc.exitCode === null) serverProc.kill()
    rmSync(tempDir, { recursive: true, force: true })
  }
}

main().catch(err => {
  console.error('❌ 回执测试失败:', err)
  if (serverProc && serverProc.exitCode === null) serverProc.kill()
  process.exit(1)
})
