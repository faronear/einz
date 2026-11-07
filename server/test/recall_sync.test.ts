/**
 * 撤回同步（message.recalled，2026-11-07）回归：
 * 撤回成功后，**同 member 的其他在线通道**收到 message.recalled 帧把本地副本
 * 一并墓碑；对端（其他成员）**绝不**收到——它们本就没拉到过这条消息（撤回的
 * 前提），给它们发帧反而泄露"存在过一条 seq=N 的消息"。
 *
 * 走 [recallMessage] 真路径（同 member 的历史通道也放行的 legacy 归因一并覆盖），
 * WS 基建照 entrance_retire.test.ts 的 harness。
 *
 * 运行：npm test（tsx test/recall_sync.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { WebSocketServer, WebSocket } from 'ws'

import { hashSessionToken } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { recallMessage } from '../src/messages.js'
import { attachWs } from '../src/ws.js'
import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

/** 一个 Space 两人：p1 有两条通道 a1（撤回发起）+ a2（自己的另一台），
 *  p2 一条通道 b1（对端观察方）。已有一条 p1 发出的消息 m-1（seq 1）。 */
function seed (): void {
  const db = getDb()
  const now = Date.now()

  db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run('space-a', 'addr-a', 'pk-a', now, now)

  const dev = db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, created_at)
     VALUES (?, ?, 'pk', 'active', ?, ?)`,
  )
  dev.run('a1', 'p1', now, now)
  dev.run('a2', 'p1', now, now)
  dev.run('b1', 'p2', now, now)

  const member = db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, status, joined_at)
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
  session.run(hashSessionToken('tok-a2'), 'a2', expires, now)
  session.run(hashSessionToken('tok-b1'), 'b1', expires, now)

  db.prepare(
    `INSERT INTO messages (message_id, space_id, sender_entrance_id, sender_member_id, type, key_version, nonce, ciphertext, server_sequence, created_at)
     VALUES ('m-1', 'space-a', 'a1', 'p1', 'text', 1, 'bm9uY2U=', 'Y2lwaGVy', 1, ?)`,
  ).run(now)
}

interface Client {
  ws: WebSocket
  frames: Array<{ type: string; payload: Record<string, unknown> }>
}

function connect (port: number, token: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?pv=${PROTOCOL_VERSION}`, {
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

test('撤回同步：自己其他在线通道收到 message.recalled；对端与发起通道都不收到', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-recall-sync-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'recall-sync.db'))
    seed()

    const a1 = await connect(port, 'tok-a1') // 撤回发起通道
    const a2 = await connect(port, 'tok-a2') // 自己的另一台（必须收到）
    const b1 = await connect(port, 'tok-b1') // 对端（绝不能收到）
    // 等三条连接的 peer.online 相互广播消化完，避免把连接期帧误判为撤回帧
    await sleep(300)

    const result = recallMessage('tok-a1', 'm-1')
    assert.equal(result.message_id, 'm-1')

    // 1) 自己的另一台收到撤回同步帧，且载荷正确
    await waitFor('a2 收到 message.recalled', () =>
      a2.frames.some(f => f.type === 'message.recalled'))
    const frame = a2.frames.find(f => f.type === 'message.recalled') as
      { payload: { message_id: string; server_sequence: number } }
    assert.equal(frame.payload.message_id, 'm-1')
    assert.equal(frame.payload.server_sequence, 1)

    // 2) 发起通道不重收（它已本地墓碑）；对端绝不收到（否则泄露消息存在性）
    await sleep(300)
    assert.deepEqual(
      a1.frames.filter(f => f.type === 'message.recalled'),
      [],
      '发起撤回的通道不重收撤回帧',
    )
    assert.deepEqual(
      b1.frames.filter(f => f.type === 'message.recalled'),
      [],
      '对端不得收到撤回帧（没拉到过这条消息，帧只会泄露其存在）',
    )

    // 3) 服务端行已真删（既有语义不回归）
    const row = getDb()
      .prepare(`SELECT COUNT(*) AS n FROM messages WHERE message_id = 'm-1'`)
      .get() as { n: number }
    assert.equal(row.n, 0, '撤回后消息行真删')
  } finally {
    wss.close()
    rmSync(dir, { recursive: true, force: true })
  }
})
