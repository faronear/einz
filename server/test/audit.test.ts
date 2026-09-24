/**
 * 审计日志测试（2026-09-13 新增）
 *
 * 验证"谁在哪条通道上、什么时候做了什么"确实落到了库里：
 *   - WS 上线/下线事件流（含在线时长、关闭码、来源 IP）
 *   - 消息「发送」是通道级（sender_entrance_id 已入库）
 *   - 消息「接收」有证据（sync 拉取进度，通道级）
 *   - 回执「已读」上报有通道级明细（receipts 表本身仍是 partner 级 HWM）
 *   - push token 变更有记录
 *   - **红线**：审计表不得出现密文 / nonce / 明文
 *
 * 运行：npm test（需先 npm run build 生成 dist/）
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { WebSocket } from 'ws'
import assert from 'node:assert/strict'
import Database from 'better-sqlite3'

// 所有请求默认带协议版本头（与客户端一致）：服务端对 API 路径做硬校验，
// 缺头/版本不符 → 400 PROTOCOL_VERSION_MISMATCH（PROTOCOL.md §1，2026-09-15 补实现）。
const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': '2', ...(init?.headers as Record<string, string> | undefined) }
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
      await fetch(`http://127.0.0.1:${port}/health`)
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

const sleep = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms))

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-audit-'))
  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(tempDir, 'einz.sqlite.db'),
      EINZ_FILES: join(tempDir, 'files')
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  serverProc.stderr?.on('data', d => process.stderr.write(`[server] ${d}`))

  try {
    await waitReady(port)

    // 1) 建空间 → 拿到通道与会话
    const create = await fetch(`http://127.0.0.1:${port}/spaces`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        creator_name: 'luk',
        public_key: Buffer.alloc(32, 7).toString('base64'),
        entrance_name: '老板的 iPhone'
      })
    })
    assert.equal(create.status, 201, 'create space should succeed')
    const created = (await create.json()) as {
      spaceId: string
      entranceId: string
      sessionToken: string
    }
    const auth = { Authorization: `Bearer ${created.sessionToken}` }
    const nonce = Buffer.alloc(24, 3).toString('base64')
    const CIPHERTEXT = Buffer.alloc(48, 9).toString('base64') // 哨兵：绝不能进审计表

    // 2) WS 上线 → 下线（等服务端写完 close 事件）
    await new Promise<void>((done, fail) => {
      const ws = new WebSocket(
        `ws://127.0.0.1:${port}/ws?pv=2`,
        { headers: { Authorization: `Bearer ${created.sessionToken}` } }
      )
      ws.on('open', () => {
        sleep(50).then(() => {
          ws.close(1000, 'bye')
          done()
        })
      })
      ws.on('error', fail)
    })
    await sleep(400)

    // 3) 发一条消息（通道级发送证据）
    const messageId = '01a0ffff-cccc-7ddd-9eee-0123456789ab'
    const post = await fetch(`http://127.0.0.1:${port}/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...auth },
      body: JSON.stringify({
        v: 1,
        type: 'text',
        key_version: 1,
        message_id: messageId,
        sender_entrance_id: created.entranceId,
        nonce,
        ciphertext: CIPHERTEXT
      })
    })
    assert.equal(post.status, 200, 'post message should succeed')

    // 4) 同步（通道级接收证据）
    const sync = await fetch(`http://127.0.0.1:${port}/sync?after=0`, { headers: auth })
    assert.equal(sync.status, 200, 'sync should succeed')

    // 5) 回执上报（通道级已读明细）
    const receipt = await fetch(`http://127.0.0.1:${port}/receipts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...auth },
      body: JSON.stringify({ delivered_upto_seq: 1, read_upto_seq: 1 })
    })
    assert.equal(receipt.status, 200, 'post receipts should succeed')

    // 6) Push token 注册
    const push = await fetch(`http://127.0.0.1:${port}/push/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...auth },
      body: JSON.stringify({ platform: 'ios', token: 'apns-token-abcdef123456' })
    })
    assert.equal(push.status, 200, 'push register should succeed')

    // ---------- 断言 ----------
    const db = new Database(join(tempDir, 'einz.sqlite.db'), { readonly: true })

    // A) 上下线事件流：一 connect 一 disconnect，都带通道、空间、IP
    const conns = db
      .prepare(
        `SELECT entrance_id, space_id, event, duration_ms, close_code, ip
         FROM connection_events ORDER BY event_id`
      )
      .all() as Array<{
      entrance_id: string
      space_id: string
      event: string
      duration_ms: number | null
      close_code: number | null
      ip: string | null
    }>
    assert.equal(conns.length, 2, '应有一条 connect + 一条 disconnect')
    assert.equal(conns[0]!.event, 'connect', '首条应为 connect')
    assert.equal(conns[1]!.event, 'disconnect', '次条应为 disconnect')
    assert.equal(conns[0]!.entrance_id, created.entranceId, '上线事件须记 entrance_id')
    assert.equal(conns[0]!.space_id, created.spaceId, '上线事件须记 space_id')
    assert.ok(conns[0]!.ip, '上线事件须记来源 IP')
    assert.ok((conns[1]!.duration_ms ?? 0) > 0, '下线事件须记本次在线时长')
    assert.equal(conns[1]!.close_code, 1000, '下线事件须记 WS 关闭码')

    // B) 发送 / 接收 / 已读 / push：四种活动都按通道记了
    const kinds = (
      db
        .prepare(`SELECT DISTINCT kind FROM entrance_activity ORDER BY kind`)
        .all() as Array<{ kind: string }>
    ).map(r => r.kind)
    for (const k of ['message.post', 'sync', 'receipt', 'push.register']) {
      assert.ok(kinds.includes(k), `entrance_activity 应含 ${k}（实际：${kinds.join(',')}）`)
    }

    const postRow = db
      .prepare(`SELECT entrance_id, space_id, detail FROM entrance_activity WHERE kind = 'message.post'`)
      .get() as { entrance_id: string; space_id: string; detail: string }
    assert.equal(postRow.entrance_id, created.entranceId, '发送明细须记发送通道')
    assert.equal(postRow.space_id, created.spaceId, '发送明细须记 space')
    assert.ok(postRow.detail.includes(messageId), '发送明细须含 message_id')

    const syncRow = db
      .prepare(`SELECT detail FROM entrance_activity WHERE kind = 'sync'`)
      .get() as { detail: string }
    assert.ok(
      JSON.parse(syncRow.detail).last_sequence >= 1,
      'sync 明细须记录该通道拉取到的进度（接收证据）'
    )

    const receiptRow = db
      .prepare(`SELECT entrance_id, detail FROM entrance_activity WHERE kind = 'receipt'`)
      .get() as { entrance_id: string; detail: string }
    assert.equal(receiptRow.entrance_id, created.entranceId, '回执明细须记上报通道')
    assert.equal(JSON.parse(receiptRow.detail).reported_read, 1, '回执明细须记原始上报值')

    // C) 红线：审计表不得出现密文 / nonce
    const dump = JSON.stringify(
      db.prepare(`SELECT * FROM entrance_activity`).all()
    )
    assert.ok(!dump.includes(CIPHERTEXT), '审计表绝不能含密文')
    assert.ok(!dump.includes(nonce), '审计表绝不能含 nonce')

    // D) push token 只落前缀，不落完整 token
    const pushRow = db
      .prepare(`SELECT detail FROM entrance_activity WHERE kind = 'push.register'`)
      .get() as { detail: string }
    assert.ok(!pushRow.detail.includes('apns-token-abcdef123456'), '审计表不得落完整 push token')
    assert.ok(pushRow.detail.includes('apns-tok'), 'push 明细应落 token 前缀便于比对')

    db.close()
    console.log('✅ 审计日志测试通过：上下线事件流 / 发送·接收·已读通道级明细 / push 变更 / 密文隔离')
  } finally {
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
  console.error('❌ 审计日志测试失败:', err)
  process.exit(1)
})
