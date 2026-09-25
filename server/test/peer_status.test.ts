/**
 * 回归：peer.online/peer.offline 只广播给**另一个人**的通道（老板 2026-09-16 实测）。
 *
 * 此前广播只排除发起通道本身（`entrance_id != 自己`），于是同一 member 的第二条通道
 * 一上线，第一台就把"对方"灯点亮——对方（B）压根还没加入空间却显示在线。
 * 现在：广播跳过与发起通道同 member 的连接，且 payload 带 member_id 供客户端自校。
 *
 * 运行：npm test（tsx test/peer_status.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { WebSocket, WebSocketServer } from 'ws'

import { hashSessionToken } from '../src/auth.js'
import { listEntrances } from '../src/entrances.js'
import { getDb, openDb } from '../src/db.js'
import { attachWs } from '../src/ws.js'

/** 一个 Space 两人：p1 有两条通道（a1/a2——同一人），p2 一条（b1——对方）。 */
function seed (): void {
  const db = getDb()
  const now = Date.now()

  db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run('space-a', 'addr-a', 'pk-a', now, now)

  const dev = db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, created_at)
     VALUES (?, ?, 'pk', 'active', ?)`,
  )
  dev.run('a1', 'p1', now)
  dev.run('a2', 'p1', now)
  dev.run('b1', 'p2', now)

  const member = db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, status, joined_at)
     VALUES (?, ?, ?, 'active', ?)`,
  )
  member.run('space-a', 'p1', 0, now)
  member.run('space-a', 'p2', 1, now)

  const session = db.prepare(
    `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
     VALUES (?, ?, 'space-a', ?, ?)`,
  )
  const expires = now + 3_600_000
  for (const [entranceId, token] of [['a1', 'tok-a1'], ['a2', 'tok-a2'], ['b1', 'tok-b1']] as const) {
    session.run(hashSessionToken(token), entranceId, expires, now)
  }
}

interface Client {
  ws: WebSocket
  frames: Array<{ type: string; payload: Record<string, unknown> }>
}

function connect (port: number, token: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?pv=2`, {
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

/** 等条件成立（WS 广播是异步的）；超时即失败，避免测试挂死。 */
async function waitFor (what: string, cond: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${what}`)
    await new Promise(r => setTimeout(r, 20))
  }
}

const sleep = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms))

test('peer 上下线广播：跳过同一 member 的通道，只给对方', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-peer-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'peer.db'))
    seed()

    const a1 = await connect(port, 'tok-a1')
    const a2 = await connect(port, 'tok-a2') // 同一人的第二条通道

    // 关键断言：a2 上线不得让 a1 以为"对方"上线（B 此时还没连）
    await sleep(300)
    assert.deepEqual(
      a1.frames.filter(f => f.type.startsWith('peer.')),
      [],
      '同一人的另一条通道上线，不该给 a1 发 peer 广播',
    )

    const b1 = await connect(port, 'tok-b1') // 真正的对方
    await waitFor('a1 收到 b1 的 peer.online', () =>
      a1.frames.some(f => f.type === 'peer.online' && f.payload.entrance_id === 'b1'))
    await waitFor('a2 收到 b1 的 peer.online', () =>
      a2.frames.some(f => f.type === 'peer.online' && f.payload.entrance_id === 'b1'))

    const online = a1.frames.find(f => f.type === 'peer.online')
    assert.equal(online?.payload.member_id, 'p2', 'payload 应带上通道所属 member_id')

    b1.ws.close()
    await waitFor('a1 收到 b1 的 peer.offline', () =>
      a1.frames.some(f => f.type === 'peer.offline' && f.payload.entrance_id === 'b1'))

    // 反向：a1 下线时同样不该惊动 a2（同一人），但要通知 b1 侧（b1 已断开，无连接）
    a1.ws.close()
    await sleep(300)
    assert.deepEqual(
      a2.frames.filter(f => f.payload.entrance_id === 'a1'),
      [],
      'a1 下线不得给同一人的 a2 发 peer 广播（a2 仍该收到 b1 的离线——b1 才是对方）',
    )

    a2.ws.close()
    await sleep(50)
  } finally {
    wss.close()
    for (const c of wss.clients) c.terminate()
    rmSync(dir, { recursive: true, force: true })
  }
})

/** 取 a1 收到的、关于 b1 的最后一帧指定类型的广播。 */
function lastAbout (
  frames: Client['frames'],
  type: string,
  entranceId: string,
): Record<string, unknown> | undefined {
  const hits = frames.filter(f => f.type === type && f.payload.entrance_id === entranceId)
  return hits.length === 0 ? undefined : hits[hits.length - 1]!.payload
}

test('online_since：进入在线态的时刻——重连不刷新；peer.offline 不带该字段', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-since-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'since.db'))
    seed()

    const a1 = await connect(port, 'tok-a1')
    const b1 = await connect(port, 'tok-b1')
    await waitFor('a1 收到 b1 的 peer.online', () =>
      a1.frames.some(f => f.type === 'peer.online' && f.payload.entrance_id === 'b1'))
    const first = lastAbout(a1.frames, 'peer.online', 'b1')!
    assert.equal(typeof first.online_since, 'number', 'peer.online 应带 online_since')

    // /entrances 与广播同源：客户端既能轮询也能靠广播增量维护
    const row = listEntrances('tok-a1').entrances.find(d => d.entrance_id === 'b1') as
      | Record<string, unknown>
      | undefined
    assert.equal(row?.online_since, first.online_since, '/entrances 的 online_since 应与广播一致')
    assert.ok(row?.connected_at != null, '在线通道应有 connected_at')

    // 重连（旧连接被踢、再连上）：不算"重新上线"→ online_since 不变，
    // 客户端列表里该通道不该跳到队首（老板 2026-09-16）
    await sleep(20)
    const b1Again = await connect(port, 'tok-b1')
    await waitFor('a1 收到 b1 重连后的 peer.online', () =>
      a1.frames.filter(f => f.type === 'peer.online' && f.payload.entrance_id === 'b1').length >= 2)
    const second = lastAbout(a1.frames, 'peer.online', 'b1')!
    assert.equal(
      second.online_since,
      first.online_since,
      '重连不得刷新 online_since（否则通道会跳到"最新上线"的位置）',
    )
    const rowAgain = listEntrances('tok-a1').entrances.find(d => d.entrance_id === 'b1') as
      | Record<string, unknown>
      | undefined
    assert.equal(rowAgain?.online_since, first.online_since, '/entrances 同样不因重连刷新')
    assert.notEqual(rowAgain?.connected_at, row?.connected_at, 'connected_at 应随本次连接刷新')

    b1Again.ws.close()
    await waitFor('a1 收到 b1 的 peer.offline', () =>
      a1.frames.some(f => f.type === 'peer.offline' && f.payload.entrance_id === 'b1'))
    assert.ok(
      !('online_since' in (lastAbout(a1.frames, 'peer.offline', 'b1') ?? {})),
      'peer.offline 不带 online_since（已下线，上线时刻无意义）',
    )

    b1.ws.close()
    a1.ws.close()
    await sleep(50)
  } finally {
    wss.close()
    for (const c of wss.clients) c.terminate()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('offline_since：断线时刻落库并可查；重连清空（离线卡片显示"什么时候下的线"）', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-offline-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'offline.db'))
    seed()

    const rowOf = (id: string): Record<string, unknown> | undefined =>
      listEntrances('tok-a1').entrances.find(d => d.entrance_id === id) as
        | Record<string, unknown>
        | undefined

    const a1 = await connect(port, 'tok-a1')
    const b1 = await connect(port, 'tok-b1')

    // 在线：没有"离线时刻"（登出后它是陈旧数据，建连时被清空）
    assert.equal(rowOf('b1')?.offline_since, null, '在线通道不应有 offline_since')

    const beforeClose = Date.now()
    b1.ws.close()
    await waitFor('a1 收到 b1 的 peer.offline', () =>
      a1.frames.some(f => f.type === 'peer.offline' && f.payload.entrance_id === 'b1'))

    // 干净下线：last_seen 归零（离线判定靠它），断线时刻落在 offline_since
    const offline = rowOf('b1')
    assert.equal(offline?.last_seen, 0, 'last_seen 归零是"离线"的判定依据，不能动')
    assert.equal(typeof offline?.offline_since, 'number', '断开应落 offline_since')
    const since = offline?.offline_since as number
    assert.ok(
      since >= beforeClose && since <= Date.now(),
      `offline_since 应落在断开前后（before=${beforeClose} got=${since}）`,
    )

    // 重连 → 清空（下次断开重新落）。不清的话，重新在线的通道会挂着一个旧时刻
    const b1Again = await connect(port, 'tok-b1')
    assert.equal(rowOf('b1')?.offline_since, null, '重连应清空 offline_since')

    b1Again.ws.close()
    a1.ws.close()
    await sleep(50)
  } finally {
    wss.close()
    for (const c of wss.clients) c.terminate()
    rmSync(dir, { recursive: true, force: true })
  }
})
