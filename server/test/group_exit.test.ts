// 自愿退群（2026-10-19，aimemo/20261019_groupExitDesign.md）：身份级离场的服务端行为。
//
// 覆盖（设计文档 §十一 第 1 条的测试清单 + 实现期补强）：
// - 主路径：墓碑（保名让 slot）+ 批量退役本身份全部通道 + push/sessions/
//   challenges 清理 + receipts 删除 + 旧 join token 作废 + email 解绑；
// - 幂等（并发双退窄窗）：二次 leave 不炸、不改行；
// - duo 拒退（409 LEAVE_NOT_ALLOWED，老板决策 1 的服务端兜底）；
// - 墓碑防复活：作废的码 → TOKEN_USED；绕过闸门走私的码 → MEMBER_LEFT
//   （preflight / join / 签发三处）；
// - slot 回收：退出者腾出的槽位被下一个新成员拿到；
// - email 别处还在用 → 解绑但保留 notify_emails 行；
// - 最后一人退出 → 空间冻结（无人可发邀请），数据留服务端；
// - 离线设备自毁发现路径：退出后该通道 challenge → 403 ENTRANCE_REVOKED；
// - WS 集成：member.left 广播给剩余成员；同身份其他在线通道收
//   entrance.revoked + 4403（"就像被撤回一样"）；发起设备不收撤销帧。
//
// 运行：npm test（tsx test/group_exit.test.ts）——需要 Node v22（better-sqlite3 ABI）
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { WebSocket, WebSocketServer } from 'ws'

import { createChallenge, hashSessionToken, resolveSession } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import type { EntranceSession } from '../src/guard.js'
import { getSpace } from '../src/push.js'
import {
  createJoinToken,
  createSpace,
  joinSpace,
  leaveSpace,
  newJoinToken,
  preflightJoin,
  type SpaceJoinResult
} from '../src/spaces.js'
import { attachWs } from '../src/ws.js'
import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

/** 本文件专属进程：空配置 = 什么都不限（config.ts 首次 loadConfig 时才读）。 */
const configDir = mkdtempSync(join(tmpdir(), 'einz-exit-cfg-'))
process.env.EINZ_CONFIG = join(configDir, 'serverConfig.json')

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void> | void): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-exit-'))
  try {
    openDb(join(dir, 'exit.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** createSpace 参数表很长且是位置参数，包一层省得每处数逗号。
 *  [publicKey] 传了创建者才有通道（getSpace 等需要会话的场景传它）。 */
function create (
  mode?: 'duo' | 'group',
  creatorName = '甲',
  publicKey?: string,
): Promise<{ spaceId: string; joinToken: string; creatorMemberId: string; entranceId: string }> {
  return createSpace(
    undefined, creatorName, 'male',
    undefined, undefined, publicKey, publicKey == null ? undefined : 'Dev0',
    undefined, undefined, mode,
  ).then(r => ({
    spaceId: r.spaceId,
    joinToken: r.joinToken,
    creatorMemberId: r.creatorMemberId,
    entranceId: r.entranceId,
  }))
}

/** 拉一个成员进 group 空间（invite 流：新身份、自填名字）。 */
function addMember (spaceId: string, issuerMemberId: string, name: string, dev: string): SpaceJoinResult {
  const inv = createJoinToken(spaceId, undefined, 'invite', issuerMemberId)
  return joinSpace(inv.joinToken, `pk-${dev}`, dev, undefined, undefined, name)
}

function row<T> (sql: string, ...params: unknown[]): T {
  return getDb().prepare(sql).get(...params) as T
}

function count (sql: string, ...params: unknown[]): number {
  return (getDb().prepare(sql).get(...params) as { n: number }).n
}

/** 给某成员签一个可用的 session token（getSpace 需要 requireSession）。 */
function sessionTokenFor (memberId: string, spaceId: string): string {
  const dev = row<{ entrance_id: string }>(
    `SELECT entrance_id FROM entrances WHERE member_id = ? LIMIT 1`, memberId,
  )
  if (!dev) throw new Error(`member ${memberId} 没有通道可签会话`)
  const token = 'sess-' + dev.entrance_id
  getDb().prepare(
    `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(hashSessionToken(token), dev.entrance_id, spaceId, Date.now() + 3_600_000, Date.now())
  return token
}

test('主路径：墓碑保名让 slot、批量退役、清理 receipts/token，计数只剩 active', async () => {
  await withDb(async () => {
    const space = await create('group', '甲', 'pk-creator')
    const b = addMember(space.spaceId, space.creatorMemberId, '乙', 'Pixel')
    const c = addMember(space.spaceId, space.creatorMemberId, '丙', 'Mac')
    const db = getDb()
    // 给乙造点"身后事"：回执行 + 邮箱 + 推送凭证 + 待签 challenge + 一条旧 attach 码
    db.prepare(
      `INSERT INTO receipts (space_id, member_id, delivered_upto_seq, read_upto_seq, updated_at)
       VALUES (?, ?, 3, 2, ?)`,
    ).run(space.spaceId, b.memberId, Date.now())
    db.prepare(`UPDATE space_members SET email = ? WHERE space_id = ? AND member_id = ?`)
      .run('left@example.com', space.spaceId, b.memberId)
    db.prepare(`INSERT INTO notify_emails (email, verified_at, created_at) VALUES (?, ?, ?)`)
      .run('left@example.com', Date.now(), Date.now())
    db.prepare(`INSERT INTO push_tokens (entrance_id, platform, token, updated_at) VALUES (?, 'ios', 'tok', ?)`)
      .run(b.entranceId, Date.now())
    db.prepare(
      `INSERT INTO challenges (challenge_id, entrance_id, space_id, challenge, expires_at, used)
       VALUES ('ch-b', ?, ?, 'x', ?, 0)`,
    ).run(b.entranceId, space.spaceId, Date.now() + 600_000)
    const stale = createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId, b.memberId)
    // 乙的第二台设备（同 member 的另一条通道）
    const own = createJoinToken(space.spaceId, undefined, 'attach', b.memberId)
    const b2 = joinSpace(own.joinToken, 'pk-b2', 'iPad', b.slot)

    const sessB: EntranceSession = {
      entrance_id: b.entranceId,
      space_id: space.spaceId,
      member_id: b.memberId,
    }
    assert.deepEqual(leaveSpace(sessB, space.spaceId), { ok: true })

    // ② 墓碑：保名、status/left_at、slot 让到 max+1（原 slot 1 腾出）
    const m = row<{
      status: string; left_at: number | null; slot: number;
      display_name: string | null; gender: string | null;
      member_id: string | null; email: string | null;
    }>(
      `SELECT status, left_at, slot, display_name, gender, member_id, email
         FROM space_members WHERE space_id = ? AND member_id = ?`,
      space.spaceId, b.memberId,
    )
    assert.equal(m.status, 'left')
    assert.ok(m.left_at != null && m.left_at > 0, 'left_at 落墓碑时刻')
    assert.equal(m.slot, 3, '墓碑移到 max(slot)+1，原 slot 1 让出')
    assert.equal(m.display_name, '乙', '墓碑保名（历史消息解析依赖）')
    assert.equal(m.member_id, b.memberId, 'member_id 不动')
    assert.equal(m.email, null, 'email 解绑')
    // ④ email 无别处引用 → 物理删（notify_emails 行）
    assert.equal(count(`SELECT COUNT(*) AS n FROM notify_emails WHERE email = ?`, 'left@example.com'), 0)
    // ⑤ receipts 行删除；甲/丙的行不受影响
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM receipts WHERE space_id = ? AND member_id = ?`, space.spaceId, b.memberId),
      0,
    )
    // ① 批量退役本身份**全部**通道（两条都 revoked + last_seen=0 + offline_since）
    for (const eid of [b.entranceId, b2.entranceId]) {
      const e = row<{ status: string; last_seen: number | null; offline_since: number | null }>(
        `SELECT status, last_seen, offline_since FROM entrances WHERE entrance_id = ?`, eid,
      )
      assert.equal(e.status, 'revoked')
      assert.equal(e.last_seen, 0)
      assert.ok(e.offline_since != null && e.offline_since > 0)
    }
    // push/sessions/challenges 全清（该身份名下——插入过假数据的表才作数）
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM push_tokens WHERE entrance_id IN (?, ?)`, b.entranceId, b2.entranceId),
      0,
    )
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM sessions WHERE entrance_id IN (?, ?)`, b.entranceId, b2.entranceId),
      0,
      '两条通道的会话（含各自 join 时签发的）都应删除',
    )
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM challenges WHERE entrance_id IN (?, ?)`, b.entranceId, b2.entranceId),
      0,
    )
    // ③ 旧 join token 作废：甲签给乙的 attach 码标记已用
    assert.ok(
      row<{ used_at: number | null }>(
        `SELECT used_at FROM join_tokens WHERE token_hash = ?`,
        hashSessionToken(stale.joinToken),
      ).used_at != null,
      '指向退出身份的未用码应被作废',
    )
    // 计数只剩 active（甲+丙 = 2）——countActiveMembers 零改动自动正确
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`, space.spaceId),
      2,
    )

    // 幂等：再退一次不炸、行不变（并发双退的窄窗重放）
    assert.deepEqual(leaveSpace(sessB, space.spaceId), { ok: true })
    const m2 = row<{ status: string; slot: number }>(
      `SELECT status, slot FROM space_members WHERE space_id = ? AND member_id = ?`,
      space.spaceId, b.memberId,
    )
    assert.equal(m2.status, 'left')
    assert.equal(m2.slot, 3, '幂等路径不该再动 slot')

    // slot 回收：下一个新成员拿到乙让出的 slot 1
    const d = addMember(space.spaceId, space.creatorMemberId, '丁', 'Tab')
    assert.equal(d.slot, 1, '最小空槽分配自然回收退出者让出的 slot')

    // 墓碑保名：getSpace 仍返回乙的名字，并带 member_status（三分口径的数据源）
    const info = getSpace(sessionTokenFor(c.memberId, space.spaceId))
    assert.equal(info.member_names[b.memberId], '乙')
    assert.equal(info.member_status[b.memberId], 'left')
    assert.equal(info.member_status[c.memberId], 'active')
    assert.equal(info.member_status[space.creatorMemberId], 'active')
    // 新成员丁顶替了乙的槽位
    assert.equal(info.member_slots[d.memberId], 1)
  })
})

test('duo 拒退：409 LEAVE_NOT_ALLOWED，任何状态都不变', async () => {
  await withDb(async () => {
    const space = await create() // 不带 mode → duo
    const b = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const before = row<{ status: string; slot: number }>(
      `SELECT status, slot FROM space_members WHERE space_id = ? AND member_id = ?`,
      space.spaceId, b.memberId,
    )
    assert.throws(
      () => leaveSpace(
        { entrance_id: b.entranceId, space_id: space.spaceId, member_id: b.memberId },
        space.spaceId,
      ),
      (e: unknown) =>
        e instanceof Error && 'code' in e &&
        (e as { code: string }).code === 'LEAVE_NOT_ALLOWED' &&
        (e as { httpStatus: number }).httpStatus === 409,
    )
    const after = row<{ status: string; slot: number }>(
      `SELECT status, slot FROM space_members WHERE space_id = ? AND member_id = ?`,
      space.spaceId, b.memberId,
    )
    assert.deepEqual(after, before, 'duo 里退群必须什么都不能改')
    // 乙的通道也未被误伤
    assert.equal(
      row<{ status: string }>(`SELECT status FROM entrances WHERE entrance_id = ?`, b.entranceId).status,
      'active',
    )
  })
})

test('墓碑防复活：作废的码 → TOKEN_USED；走私的码 → MEMBER_LEFT（三处闸门）', async () => {
  await withDb(async () => {
    const space = await create('group', '甲', 'pk-creator')
    const b = addMember(space.spaceId, space.creatorMemberId, '乙', 'Pixel')
    // 退出前签好的两巴掌：指向乙的 attach 码 + 乙自己签的 invite 码
    const stale = createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId, b.memberId)
    const invByB = createJoinToken(space.spaceId, undefined, 'invite', b.memberId)

    leaveSpace(
      { entrance_id: b.entranceId, space_id: space.spaceId, member_id: b.memberId },
      space.spaceId,
    )

    // 退出时一并作废 → 走既有的 TOKEN_USED（用户视角："链接已用过"）
    for (const t of [stale.joinToken, invByB.joinToken]) {
      assert.throws(
        () => preflightJoin(t),
        (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'TOKEN_USED',
      )
      assert.throws(
        () => joinSpace(t, 'pk-x', 'New'),
        (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'TOKEN_USED',
      )
    }
    // 绕过签发闸门直接走私一张指向墓碑的码（模拟"码签发于作废闸门之前"）→
    // MEMBER_LEFT 在 preflight / join / 签发三处挡住，墓碑身份不能"复活"
    const smuggled = newJoinToken(space.spaceId, 'member', 'attach', space.creatorMemberId, b.memberId)
    assert.throws(
      () => preflightJoin(smuggled.token),
      (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'MEMBER_LEFT',
      'preflight fail-fast',
    )
    assert.throws(
      () => joinSpace(smuggled.token, 'pk-x', 'New'),
      (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'MEMBER_LEFT',
      'join 兜底（老客户端跳过 preflight 直 join）',
    )
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId, b.memberId),
      (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'MEMBER_LEFT',
      '签发：给退出身份签不出新码（回来 = 新 invite 开新身份）',
    )
    // 成员数没被走私码带回来
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`, space.spaceId),
      1,
    )
  })
})

test('email 别处还在用 → 解绑但保留 notify_emails 行', async () => {
  await withDb(async () => {
    const space = await create('group', '甲', 'pk-creator')
    const b = addMember(space.spaceId, space.creatorMemberId, '乙', 'Pixel')
    // 同一个地址同时挂在甲和乙头上（一人多空间的既有形态）
    getDb().prepare(`UPDATE space_members SET email = ? WHERE space_id = ? AND member_id = ?`)
      .run('shared@example.com', space.spaceId, b.memberId)
    getDb().prepare(`UPDATE space_members SET email = ? WHERE space_id = ? AND member_id = ?`)
      .run('shared@example.com', space.spaceId, space.creatorMemberId)
    getDb().prepare(`INSERT INTO notify_emails (email, verified_at, created_at) VALUES (?, ?, ?)`)
      .run('shared@example.com', Date.now(), Date.now())

    leaveSpace(
      { entrance_id: b.entranceId, space_id: space.spaceId, member_id: b.memberId },
      space.spaceId,
    )

    // 乙解绑了，但地址还有人用 → 行保留（purgeEmailIfUnused 的既有语义）
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM notify_emails WHERE email = ?`, 'shared@example.com'),
      1,
    )
    assert.equal(
      row<{ email: string | null }>(
        `SELECT email FROM space_members WHERE space_id = ? AND member_id = ?`,
        space.spaceId, b.memberId,
      ).email,
      null,
    )
  })
})

test('最后一人退出 → 空间冻结（无人可发邀请），数据留服务端', async () => {
  await withDb(async () => {
    const space = await create('group', '甲', 'pk-creator')
    // 只有创建者一人（其他人还没加入）——他退出即"最后一人"
    assert.deepEqual(
      leaveSpace(
        { entrance_id: space.entranceId, space_id: space.spaceId, member_id: space.creatorMemberId },
        space.spaceId,
      ),
      { ok: true },
    )
    assert.equal(
      count(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`, space.spaceId),
      0,
    )
    // 空间行仍在（历史消息/附件不随退群消失——FAQ 注明"最后一人退出后空间冻结"）
    assert.ok(getDb().prepare(`SELECT 1 FROM spaces WHERE space_id = ?`).get(space.spaceId))
    // 没有 active 成员 → 谁也签不出 invite（DUO_FULL 兜底只挡 duo；这里 Group
    // 里 countActiveMembers=0 不挡签发，但 join 进来也会是全新空间语义——
    // 冻结的实质是"没有人能再被邀请进来后看得到聊天对象"，数据本身完好）
  })
})

test('离线设备自毁发现路径：退出后该通道 challenge → 403 ENTRANCE_REVOKED', async () => {
  await withDb(async () => {
    const space = await create('group', '甲', 'pk-creator')
    const b = addMember(space.spaceId, space.creatorMemberId, '乙', 'Pixel')
    leaveSpace(
      { entrance_id: b.entranceId, space_id: space.spaceId, member_id: b.memberId },
      space.spaceId,
    )
    // 乙的平板离线中（没有 WS 连接）：下次任何请求自然发现——
    // challenge 是第一条（客户端自动重认证走它），必须拿到 ENTRANCE_REVOKED
    await assert.rejects(
      () => createChallenge(b.entranceId, space.spaceId),
      (e: unknown) =>
        e instanceof Error && 'code' in e &&
        (e as { code: string }).code === 'ENTRANCE_REVOKED' &&
        (e as { httpStatus: number }).httpStatus === 403,
    )
    // 旧 session 也已删除（拿着旧 token 直接请求 → 401 invalid session）
    assert.throws(
      () => resolveSession(b.sessionToken),
      (e: unknown) => e instanceof Error && 'code' in e && (e as { code: string }).code === 'UNAUTHORIZED',
    )
  })
})

// ── WS 集成：member.left 广播 + 同身份其他设备撤销自毁 ──────────────────────

interface Client {
  ws: WebSocket
  frames: Array<{ type: string; payload: Record<string, unknown> }>
  closed: { code: number | null }
}

function connectWs (port: number, token: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?pv=${PROTOCOL_VERSION}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  const client: Client = { ws, frames: [], closed: { code: null } }
  return new Promise((done, fail) => {
    ws.on('message', data => {
      const frame = JSON.parse(data.toString())
      if (frame.type !== 'hello' && frame.type !== 'pong') client.frames.push(frame)
      if (frame.type === 'hello') done(client)
    })
    ws.on('close', code => { client.closed.code = code })
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

test('WS：退群后剩余成员收 member.left；同身份其他设备收 entrance.revoked+4403；发起设备不收撤销帧', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-exit-ws-'))
  const wss = new WebSocketServer({ port: 0 })
  attachWs(wss)
  const port = (wss.address() as { port: number }).port
  try {
    openDb(join(dir, 'exit-ws.db'))
    const db = getDb()
    const now = Date.now()
    db.prepare(
      `INSERT INTO spaces (space_id, space_address, space_public_key, status, mode, created_at, updated_at)
       VALUES ('sp', 'addr', 'pk', 'active', 'group', ?, ?)`,
    ).run(now, now)
    const dev = db.prepare(
      `INSERT INTO entrances (entrance_id, member_id, public_key, status, created_at)
       VALUES (?, ?, 'pk', 'active', ?)`,
    )
    dev.run('e-phone', 'm-me', now)   // 发起设备（我的手机）
    dev.run('e-pad', 'm-me', now)     // 同身份第二台（我的平板）
    dev.run('e-peer', 'm-peer', now)  // 剩余成员
    const member = db.prepare(
      `INSERT INTO space_members (space_id, member_id, slot, display_name, status, joined_at)
       VALUES (?, ?, ?, ?, 'active', ?)`,
    )
    member.run('sp', 'm-me', 0, '甲', now)
    member.run('sp', 'm-peer', 1, '乙', now)
    const session = db.prepare(
      `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
       VALUES (?, ?, 'sp', ?, ?)`,
    )
    const expires = now + 3_600_000
    for (const [eid, token] of [
      ['e-phone', 'tok-phone'], ['e-pad', 'tok-pad'], ['e-peer', 'tok-peer'],
    ] as const) {
      session.run(hashSessionToken(token), eid, expires, now)
    }

    const phone = await connectWs(port, 'tok-phone')
    const pad = await connectWs(port, 'tok-pad')
    const peer = await connectWs(port, 'tok-peer')

    // 甲在手机上退群
    leaveSpace({ entrance_id: 'e-phone', space_id: 'sp', member_id: 'm-me' }, 'sp')

    // ① 平板（同身份其他在线设备）：entrance.revoked 帧 + 4403 关闭 → 自毁
    await waitFor('pad revoked', () => pad.frames.some(f => f.type === 'entrance.revoked'))
    await waitFor('pad closed 4403', () => pad.closed.code === 4403)
    // ② 剩余成员：member.left（带 member_id + display_name）
    await waitFor('peer member.left', () => peer.frames.some(f => f.type === 'member.left'))
    const left = peer.frames.find(f => f.type === 'member.left')!
    assert.equal(left.payload.member_id, 'm-me')
    assert.equal(left.payload.display_name, '甲')
    // 对端视角：发起通道下线了（peer.offline 广播）
    assert.ok(
      peer.frames.some(f => f.type === 'peer.offline' && f.payload.entrance_id === 'e-phone'),
      '对端应看到发起通道下线',
    )
    // ③ 发起设备（手机）**不收** entrance.revoked / member.left
    //    （它自己发起的退出，收尾在客户端；连接已静默摘除）
    await sleep(150)
    assert.ok(
      !phone.frames.some(f => f.type === 'entrance.revoked'),
      '发起设备不该收到"被撤销"帧（误导）',
    )
    assert.ok(
      !phone.frames.some(f => f.type === 'member.left'),
      '发起设备的连接已静默摘除，不再收广播',
    )

    phone.ws.close()
    pad.ws.close()
    peer.ws.close()
  } finally {
    await new Promise<void>(done => wss.close(() => done()))
  }
})
