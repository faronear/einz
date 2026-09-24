/**
 * 未读条数 `GET /messages/unread`（`receipts.unreadCount`）回归。
 *
 * 多空间列表角标的依据：**服务端派生**——消息 + 我上报的读取水位（receipts.read_upto_seq）。
 * 四个必须立住的点：
 * 1. 只数"晚于我读取水位"的；
 * 2. **必须走 member 维度**排除自己：同一身份的第二条通道发来的消息不是未读
 *    （只比 entrance_id 会把它算进来——这是最容易错的点）；
 * 3. 没有 receipts 行 = 从没读过 = 对方的全部消息都算未读；
 * 4. 只数本空间（跨空间不串）。
 *
 * 运行：npm test（tsx test/unread.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { hashSessionToken } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { unreadCount } from '../src/receipts.js'

const SPACE = 'space-a'
const OTHER_SPACE = 'space-b'
const ME = 'member-me'
const PEER = 'member-peer'
const MY_DEVICE = 'dev-me'
const MY_OTHER_DEVICE = 'dev-me-2'
const PEER_DEVICE = 'dev-peer'

/** 建库 + 一个空间：我（两台登记项）、对方（一台），5 条消息，我读到 seq=3。 */
function seed (): void {
  const db = getDb()
  const now = Date.now()

  const space = db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
  space.run(SPACE, 'addr-a', 'pk-a', now, now)
  space.run(OTHER_SPACE, 'addr-b', 'pk-b', now, now)

  const dev = db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, created_at)
     VALUES (?, ?, 'pk', 'active', ?, ?)`,
  )
  dev.run(MY_DEVICE, ME, now, now)
  dev.run(MY_OTHER_DEVICE, ME, now, now) // 同一身份的第二台登记项
  dev.run(PEER_DEVICE, PEER, now, now)

  const member = db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, status, joined_at)
     VALUES (?, ?, ?, 'active', ?)`,
  )
  member.run(SPACE, ME, 0, now)
  member.run(SPACE, PEER, 1, now)

  const session = db.prepare(
    `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
  session.run(hashSessionToken('tok-me'), MY_DEVICE, SPACE, now + 3_600_000, now)
  session.run(hashSessionToken('tok-peer'), PEER_DEVICE, SPACE, now + 3_600_000, now)

  const msg = db.prepare(
    `INSERT INTO messages (message_id, space_id, sender_entrance_id, type, key_version, nonce, ciphertext, server_sequence, created_at)
     VALUES (?, ?, ?, 'text', 1, 'n', 'c', ?, ?)`,
  )
  msg.run('m1', SPACE, MY_DEVICE, 1, now) // 我发的
  msg.run('m2', SPACE, PEER_DEVICE, 2, now) // 对方
  msg.run('m3', SPACE, MY_OTHER_DEVICE, 3, now) // 我的另一条通道发的
  msg.run('m4', SPACE, PEER_DEVICE, 4, now) // 对方
  msg.run('m5', SPACE, PEER_DEVICE, 5, now) // 对方
  msg.run('x1', OTHER_SPACE, PEER_DEVICE, 1, now) // 别的空间，不该被算进来

  db.prepare(
    `INSERT INTO receipts (space_id, member_id, delivered_upto_seq, read_upto_seq, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(SPACE, ME, 3, 3, now)
}

function withDb (fn: () => void): void {
  const dir = mkdtempSync(join(tmpdir(), 'einz-unread-'))
  try {
    openDb(join(dir, 'unread.db'))
    seed()
    fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('unread：只数"晚于我读取水位"的对方消息（member 维度排除我自己）', () => {
  withDb(() => {
    // 读到 seq=3 → seq4 / seq5 是未读；seq3 虽然晚于水位但**是我另一条通道发的**，不算
    assert.equal(unreadCount('tok-me').unread, 2)
  })
})

test('unread：水位推进到最新 → 0；没有 receipts 行 → 对方的全部消息都算未读', () => {
  withDb(() => {
    const db = getDb()
    db.prepare(`UPDATE receipts SET read_upto_seq = 5 WHERE space_id = ? AND member_id = ?`).run(SPACE, ME)
    assert.equal(unreadCount('tok-me').unread, 0, '读到最新 → 没有未读')

    db.prepare(`DELETE FROM receipts WHERE space_id = ? AND member_id = ?`).run(SPACE, ME)
    // 没读过：m2 / m4 / m5 三条（m1 我发的、m3 我另一条通道发的都不算）
    assert.equal(unreadCount('tok-me').unread, 3, '没有 receipts 行 = 全部未读')
  })
})

test('unread：按 member 看（对方的角度与我不同），且不串其他空间', () => {
  withDb(() => {
    // 对方：我的 m1 与 m3 对它都是未读（它没有 receipts 行）；其他空间的消息不算
    assert.equal(unreadCount('tok-peer').unread, 2)
  })
})
