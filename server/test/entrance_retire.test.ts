/**
 * 回归：本机自助退役 `POST /entrances/retire`（2026-09-21 新增）。
 *
 * 客户端"重置本通道"原先只清本地数据，服务端这条通道的注册表项、Push Token、会话全留着，
 * 对方 /entrances 里是一台永远在线的幽灵——而 POST /entrances/:id/revoke 禁止自撤，谁也删不掉它。
 *
 * 两条**必须立住**的边界（老板 2026-09-21 定稿）：
 * 1. 退役**不发 entrance.revoked**：那是客户端自毁本地数据的授权信号。退役只认 session，
 *    若由它发出这帧，偷到 session 的人就能远程擦通道，等于给口令闸门挖了条旁路。
 * 2. 退役要**立刻让对端看到下线**：光靠客户端自己断连不可靠（客户端可能迟迟不退），
 *    而心跳每 30s 还会给连接续 last_seen，把已退役的通道刷成在线。
 *
 * 运行：npm test（tsx test/entrance_retire.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { WebSocketServer, WebSocket } from 'ws'

import { hashSessionToken } from '../src/auth.js'
import { listEntrances, retireEntrance } from '../src/entrances.js'
import { getDb, openDb } from '../src/db.js'
import { attachWs } from '../src/ws.js'

/** 一个 Space 两人：a1（p1，本次退役的那台）与 b1（p2，观察方）。 */
function seed (): void {
  const db = getDb()
  const now = Date.now()

  db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run('space-a', 'addr-a', 'pk-a', now, now)

  const dev = db.prepare(
    `INSERT INTO entrances (entrance_id, partner_id, public_key, status, last_seen, created_at)
     VALUES (?, ?, 'pk', 'active', ?, ?)`,
  )
  dev.run('a1', 'p1', now, now)
  dev.run('b1', 'p2', now, now)

  const member = db.prepare(
    `INSERT INTO space_members (space_id, partner_id, slot, status, joined_at)
     VALUES (?, ?, ?, 'active', ?)`,
  )
  member.run('space-a', 'p1', 0, now)
  member.run('space-a', 'p2', 1, now)

  const expires = now + 3_600_000
  const session = db.prepare(
    `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
     VALUES (?, ?, 'space-a', ?, ?)`,
  )
  session.run(hashSessionToken('tok-a1'), 'a1', expires, now)
  session.run(hashSessionToken('tok-b1'), 'b1', expires, now)

  const push = db.prepare(
    `INSERT INTO push_tokens (entrance_id, platform, token, updated_at) VALUES (?, 'ios', ?, ?)`,
  )
  push.run('a1', 'apns-a1', now)
  push.run('b1', 'apns-b1', now)

  // 遗留的待签 challenge：退役必须清掉——它能被重放签发新会话，让幽灵复活
  const challenge = db.prepare(
    `INSERT INTO challenges (challenge_id, entrance_id, space_id, challenge, expires_at, used)
     VALUES (?, ?, 'space-a', 'ch', ?, 0)`,
  )
  challenge.run('chal-a1', 'a1', expires)
  challenge.run('chal-b1', 'b1', expires)
}

function count (sql: string, param: string): number {
  const row = getDb().prepare(sql).get(param) as { n: number }
  return row.n
}

interface Client {
  ws: WebSocket
  frames: Array<{ type: string; payload: Record<string, unknown> }>
}

function connect (port: number, token: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?pv=1`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  const client: Client = { ws, frames: [] }
  return new Promise((done, fail) => {
    ws.on('message', data => {
      const frame = JSON.parse(data.toString())
      if (frame.type !== 'hello' && frame.type !== 'pong') client.frames.push(frame)
      if (frame.type === 'hello') done(client)
    })
    ws.on('error', fail)
  })
}

async function waitFor (what: string, cond: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${what}`)
    await new Promise(r => setTimeout(r, 20))
  }
}

const sleep = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms))

test('retireEntrance：清会话/Push/待签 challenge，通道置 revoked，且不波及其他通道', () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-retire-'))
  try {
    openDb(join(dir, 'retire.db'))
    seed()

    assert.equal(retireEntrance('tok-a1').ok, true, '自助退役应成功')

    const row = getDb()
      .prepare(`SELECT status, last_seen FROM entrances WHERE entrance_id = 'a1'`)
      .get() as { status: string; last_seen: number | null }
    assert.equal(row.status, 'revoked', '退役后须为 revoked（配置层只认这个状态）')
    assert.equal(row.last_seen, 0, 'last_seen 归零：已退役不该显示为在线')

    // entrances 行**保留**：删了它，messages.sender_entrance_id 会失去归属，且配置层会把它
    // 当成"未登记"（FORBIDDEN）而非"已退役"（ENTRANCE_REVOKED）——两者在客户端语义不同
    assert.equal(count(`SELECT COUNT(*) AS n FROM entrances WHERE entrance_id = ?`, 'a1'), 1)

    for (const [table, why] of [
      ['sessions', '会话即登录态'],
      ['push_tokens', '否则继续给一条已经不存在的通道推送'],
      ['challenges', '待签会话可重放签发新会话，让幽灵复活'],
    ] as const) {
      assert.equal(count(`SELECT COUNT(*) AS n FROM ${table} WHERE entrance_id = ?`, 'a1'), 0, why)
    }

    // 对方的一切不受影响
    const peerRow = getDb()
      .prepare(`SELECT status FROM entrances WHERE entrance_id = 'b1'`)
      .get() as { status: string }
    assert.equal(peerRow.status, 'active', '不得动对方通道')
    assert.equal(count(`SELECT COUNT(*) AS n FROM push_tokens WHERE entrance_id = ?`, 'b1'), 1)
    assert.equal(count(`SELECT COUNT(*) AS n FROM sessions WHERE entrance_id = ?`, 'b1'), 1)
    assert.equal(count(`SELECT COUNT(*) AS n FROM challenges WHERE entrance_id = ?`, 'b1'), 1)

    // 会话已删：同 token 再来一次 → 401（不是 403 ENTRANCE_REVOKED，那条属于"被人撤销"）
    let again: unknown
    try {
      retireEntrance('tok-a1')
    } catch (e) {
      again = e
    }
    assert.equal((again as { code?: string } | undefined)?.code, 'UNAUTHORIZED', '退役后同 token 应失效')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('retireEntrance：无凭证 → 401（身份只认 session，没有口令兜底）', () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-retire-auth-'))
  try {
    openDb(join(dir, 'retire.db'))
    seed()
    const err = ((): unknown => {
      try {
        retireEntrance('tok-unknown')
        return null
      } catch (e) {
        return e
      }
    })()
    assert.equal((err as { code?: string } | null)?.code, 'UNAUTHORIZED')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('retireEntrance：对端收到 peer.offline，**绝无** entrance.revoked；本机连接不被关', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-retire-ws-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'retire.db'))
    seed()

    const a1 = await connect(port, 'tok-a1')
    const b1 = await connect(port, 'tok-b1')
    await waitFor('b1 上线被 a1 看到', () =>
      a1.frames.some(f => f.type === 'peer.online' && f.payload.entrance_id === 'b1'))

    const seenBySelf = a1.frames.length // 退役前本机已收到的帧（b1 上线的 peer.online）
    retireEntrance('tok-a1')

    // 1) 对端立刻看到下线（无需等客户端自己断连、也不靠 30s 轮询兜底）
    await waitFor('b1 收到 a1 的 peer.offline', () =>
      b1.frames.some(f => f.type === 'peer.offline' && f.payload.entrance_id === 'a1'))

    // 2) 自毁信号绝不由退役发出：否则"偷到 session"等同于"远程擦通道"
    await sleep(300)
    assert.deepEqual(
      [...a1.frames, ...b1.frames].filter(f => f.type === 'entrance.revoked'),
      [],
      'entrance.revoked 只属于"被对方口令撤销"这条路径，退役不得发出',
    )

    // 3) 本机的 WS 不被主动关闭：任何关闭都会让客户端重连撞 403 ENTRANCE_REVOKED → 同样自毁
    assert.equal(a1.ws.readyState, WebSocket.OPEN, '退役不得关闭本机连接（关闭=触发客户端自毁）')
    assert.deepEqual(a1.frames.slice(seenBySelf), [], '退役后本机不该再收到任何帧')

    // 4) 已摘出在线表：心跳不再给它续 last_seen，/entrances 里也不再显示在线
    await waitFor('a1 从在线表消失', () => {
      const row = listEntrances('tok-b1').entrances.find(d => d.entrance_id === 'a1') as
        | Record<string, unknown>
        | undefined
      return row?.connected_at == null
    })
    const caller = listEntrances('tok-b1').entrances.find(d => d.entrance_id === 'a1') as
      | Record<string, unknown>
      | undefined
    assert.equal(caller?.status, 'revoked', '对方 /entrances 应看到 a1 已退役')
    assert.equal(caller?.online_since, null, '退役通道没有在线时刻')

    b1.ws.close()
    a1.ws.close()
    await sleep(50)
  } finally {
    wss.close()
    for (const c of wss.clients) c.terminate()
    rmSync(dir, { recursive: true, force: true })
  }
})
