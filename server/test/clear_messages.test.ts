/**
 * 「删除所有消息」（高级安全，2026-10-02）回归测试。
 *
 * 核心不变式：**序号高水位**——clearMessages 整表清掉消息行后，server_sequence
 * 绝不回卷。否则双方客户端的同步游标（after=旧水位）会永远滤掉重新从 1 分配的
 * 新消息，且无任何报错（静默丢数据，最难查的那类 bug）。
 *
 * 运行：npm test（直接调函数，无需起 HTTP server——clearMessages 是纯 DB 原语）。
 */
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, getDb } from '../src/db.js'
import { hashSessionToken } from '../src/auth.js'
import { postMessage, clearMessages } from '../src/messages.js'

const MY = 'dev-clear-me'
const SPACE = '11111111-2222-3333-4444-555555555555' // 附件删除走 assertSafeSpaceId，用 UUID 形态

function seed (): string {
  const dir = mkdtempSync(join(tmpdir(), 'einz-clear-msg-'))
  openDb(join(dir, 'clear.db'))
  const db = getDb()
  const now = Date.now()
  db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, created_at)
     VALUES (?, ?, 'pk', 'active', ?, ?)`,
  ).run(MY, 'member-clear', now - 3_600_000, now)
  db.prepare(
    `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(hashSessionToken('tok-clear'), MY, SPACE, now + 3_600_000, now)
  return dir
}

const env = (id: string) =>
  ({ v: 1, type: 'text', key_version: 1, message_id: id, sender_entrance_id: MY, nonce: 'n', ciphertext: 'c' })

test('删除所有消息：清空后序号不回卷，附件随删', async () => {
  const dir = seed()
  try {
    // 三条消息 seq 1..3 + 一条 m1 的附件（无真实 blob 文件，文件清理 best-effort 跳过）
    for (const id of ['m1', 'm2', 'm3']) {
      const r = postMessage('tok-clear', env(id))
      assert.equal(r.server_sequence, id === 'm1' ? 1 : id === 'm2' ? 2 : 3)
    }
    const db = getDb()
    db.prepare(
      `INSERT INTO attachments (attachment_id, message_id, space_id, key_version, size, sha256, nonce, storage_path, created_at)
       VALUES ('att-1', 'm1', ?, 1, 10, 'sha', 'n', 'x/att-1', ?)`,
    ).run(SPACE, Date.now())

    const res = clearMessages('tok-clear')
    assert.deepEqual(res, { cleared: 3, attachments: 1 })
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM messages WHERE space_id = ?`).get(SPACE).n, 0)
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM attachments WHERE space_id = ?`).get(SPACE).n, 0)
    // 高水位落 meta
    assert.equal(
      db.prepare(`SELECT value FROM meta WHERE key = ?`).get(`messages_seq_watermark.${SPACE}`).value,
      '3'
    )

    // ★ 清空后的新消息续 4，不回卷到 1（否则客户端游标永远收不到它）
    const after = postMessage('tok-clear', env('m4'))
    assert.equal(after.server_sequence, 4)

    // 再清一轮：水位只前进（4 > 3），下一次续 5
    assert.deepEqual(clearMessages('tok-clear'), { cleared: 1, attachments: 0 })
    assert.equal(postMessage('tok-clear', env('m5')).server_sequence, 5)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
