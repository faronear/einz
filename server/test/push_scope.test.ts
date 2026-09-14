/**
 * 回归：sendPushHint 只投给**同一 Space** 的设备（老板 2026-09-14 要求修）。
 *
 * 此前它只按 `device_id != 自己` 取 push_tokens —— 一旦接上真实推送，
 * 一条消息会把"有新消息"提示推给这台服务器上**所有空间**的设备（跨空间泄露
 * "谁在发消息"）。现在设备经 person_id → space_members 归属 Space，按 Space 收敛。
 *
 * 运行：npm test（tsx test/push_scope.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { getDb, openDb } from '../src/db.js'
import { sendPushHint } from '../src/push.js'

/** 建两个 Space：A 里有 a1/a2（p1/p2），B 里有 b1（p3）。b1 绝不该收到 A 的推送。 */
function seed (): void {
  const db = getDb()
  const now = Date.now()
  const space = db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
  space.run('space-a', 'addr-a', 'pk-a', now, now)
  space.run('space-b', 'addr-b', 'pk-b', now, now)

  const dev = db.prepare(
    `INSERT INTO devices (device_id, person_id, public_key, status, created_at)
     VALUES (?, ?, 'pk', 'active', ?)`,
  )
  dev.run('a1', 'p1', now)
  dev.run('a2', 'p2', now)
  dev.run('b1', 'p3', now)
  // 已撤销的设备：即使在同一 Space 也不该收到
  db.prepare(
    `INSERT INTO devices (device_id, person_id, public_key, status, created_at)
     VALUES (?, ?, 'pk', 'revoked', ?)`,
  ).run('a3', 'p1', now)

  const member = db.prepare(
    `INSERT INTO space_members (space_id, person_id, partner_slot, status, joined_at)
     VALUES (?, ?, ?, 'active', ?)`,
  )
  member.run('space-a', 'p1', 0, now)
  member.run('space-a', 'p2', 1, now)
  member.run('space-b', 'p3', 0, now)

  const token = db.prepare(
    `INSERT INTO push_tokens (device_id, platform, token, updated_at) VALUES (?, 'ios', ?, ?)`,
  )
  token.run('a1', 'apns-a1', now)
  token.run('a2', 'apns-a2', now)
  token.run('a3', 'apns-a3', now)
  token.run('b1', 'apns-b1', now)
}

test('sendPushHint：只投给同一 Space 的在用设备，不跨空间、不投已撤销', () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-push-'))
  try {
    openDb(join(dir, 'push.db'))
    seed()

    // sendPushHint 现在只打日志 → 捕获日志看它选了谁
    const lines: string[] = []
    const original = console.log
    console.log = (...args: unknown[]) => {
      lines.push(args.join(' '))
    }
    try {
      sendPushHint('space-a', 'a1')
    } finally {
      console.log = original
    }

    assert.equal(lines.length, 1, 'A 空间除 a1 外只有 a2 该收到：\n' + lines.join('\n'))
    assert.match(lines[0], /device=a2/, '应投给同空间的 a2')
    assert.doesNotMatch(lines[0], /device=b1/, '不得跨 Space 投给 b1')
    assert.doesNotMatch(lines[0], /device=a1/, '不得投给发送者自己')
    assert.doesNotMatch(lines[0], /device=a3/, '不得投给已撤销的设备')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
