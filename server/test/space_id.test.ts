/**
 * `space_id` 字符集校验回归：**它是客户端自报的**（协议 §3.4），而后续会被用作
 * 附件存储的一级目录名（per-space 分片）——放行 `/`、`\`、`.` 就等于给了客户端
 * 一个"写任意路径"的原语（见 src/safeId.ts 的注释）。
 *
 * 三条边界：① 正常 UUIDv4 通过；② 路径穿越/含点/含斜杠一律 400；③ 不传时服务端
 * 自生成（randomUUID）不受影响。
 *
 * 运行：npm test（tsx test/space_id.test.ts）——需要 Node v22（better-sqlite3 ABI）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { openDb } from '../src/db.js'
import { createSpace } from '../src/spaces.js'

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-spaceid-'))
  try {
    openDb(join(dir, 'spaceid.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('客户端自报的 UUIDv4 通过（正常路径不受影响）', async () => {
  await withDb(async () => {
    const uuid = '3f2a1b4c-5d6e-4f70-8a91-2b3c4d5e6f70'
    const space = await createSpace(uuid, '我', 'male', '伴侣', 'female')
    assert.equal(space.spaceId, uuid, '合法 space_id 应原样采用')
  })
})

test('路径穿越/非法字符一律 400，且不得落库', async () => {
  await withDb(async () => {
    const bad = [
      '../../../../etc/passwd', // 穿越
      'a/../b', // 相对路径
      '.', '..', // 当前/上级目录
      'space.d/evil', // 含点（将来拼目录名同样危险）
      'a\\b', // 反斜杠（Windows）
      '', // 空串走服务端生成，不算非法（单独断言）
      'x'.repeat(65), // 超长
    ]
    for (const id of bad) {
      if (id === '') continue
      // createSpace 是 async：断言的是 rejected promise，不是同步 throw
      await assert.rejects(
        () => createSpace(id, '我', 'male', '伴侣', 'female'),
        (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
        `非法 space_id 应 400：${id}`,
      )
    }
  })
})

test('不传 space_id 时服务端自生成（randomUUID，恒合规）', async () => {
  await withDb(async () => {
    const a = await createSpace(undefined, '我', 'male', '伴侣', 'female')
    const b = await createSpace('', '我', 'male', '伴侣', 'female')
    assert.match(a.spaceId, /^[0-9a-f-]{36}$/, '未传时服务端生成 UUID')
    assert.notEqual(a.spaceId, b.spaceId, '两次生成不得相同')
  })
})
