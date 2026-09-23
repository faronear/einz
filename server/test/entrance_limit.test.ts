/**
 * `maxEntrancesPerSpace`（单空间通道数量上限）回归：**防滥用**（老板 2026-09-23）。
 *
 * 产品上通道不限量（同身份多通道是设计本意），但一个秘境被灌进成百上千条通道
 * 会白吃存储与推送资源——用 serverConfig.json 的 maxEntrancesPerSpace 做总闸。
 *
 * 三条边界：① 超限加入被拒（409 ENTRANCE_LIMIT_REACHED）；② **撤销/退役不退
 * 额度**（entrances 行只标记 revoked、不删除，否则"开通→销毁→再开通"可无限刷）；
 * ③ 上限只作用于**本空间**（另一个空间不受影响）。
 *
 * 运行：npm test（tsx test/entrance_limit.test.ts）——需要 Node v22（better-sqlite3 ABI）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { retireEntrance } from '../src/entrances.js'
import { createSpace, createJoinToken, joinSpace } from '../src/spaces.js'

/** 临时配置：本文件专属进程，config.ts 在首次 loadConfig 时才读（缓存惰性）。 */
const configDir = mkdtempSync(join(tmpdir(), 'einz-cfg-'))
process.env.EINZ_CONFIG = join(configDir, 'serverConfig.json')
writeFileSync(process.env.EINZ_CONFIG, JSON.stringify({ maxEntrancesPerSpace: 2 }))

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void> | void): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-entrance-'))
  try {
    openDb(join(dir, 'entrance.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** 该空间登记过的通道总数（含已撤销——与服务端计数口径一致）。 */
function entranceCount (spaceId: string): number {
  const row = getDb()
    .prepare(
      `SELECT COUNT(*) AS n FROM entrances d
       JOIN space_members sm ON sm.partner_id = d.partner_id
       WHERE sm.space_id = ?`,
    )
    .get(spaceId) as { n: number }
  return row.n
}

test('上限 2：创建占 1 条，第 2 条能进，第 3 条被拒（409）', async () => {
  await withDb(async () => {
    const space = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-a', 'iPhone',
    )
    assert.equal(entranceCount(space.spaceId), 1, '创建者的第一条通道就占额度')

    joinSpace(space.joinToken, 'pk-b', 'Pixel', 1)
    assert.equal(entranceCount(space.spaceId), 2, '第 2 条通道应放行')

    const third = createJoinToken(space.spaceId)
    assert.throws(
      () => joinSpace(third.joinToken, 'pk-c', 'Mac', 0),
      (e: unknown) => e instanceof ApiError && e.code === 'ENTRANCE_LIMIT_REACHED' && e.httpStatus === 409,
      '第 3 条通道应被上限拒绝',
    )
    assert.equal(entranceCount(space.spaceId), 2, '被拒的加入不得留下通道')
  })
})

test('销毁不退额度：退役（revoked）后仍占额度，不能靠反复开通/销毁刷量', async () => {
  await withDb(async () => {
    const space = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-a', 'iPhone',
    )
    const second = joinSpace(space.joinToken, 'pk-b', 'Pixel', 1)
    // 第二条通道自助退役：entrances 行只标记 revoked、不删除
    retireEntrance(second.sessionToken)
    const revoked = getDb()
      .prepare(`SELECT status FROM entrances WHERE entrance_id = ?`)
      .get(second.entranceId) as { status: string }
    assert.equal(revoked.status, 'revoked')
    assert.equal(entranceCount(space.spaceId), 2, '撤销的通道仍计入额度')

    const third = createJoinToken(space.spaceId)
    assert.throws(
      () => joinSpace(third.joinToken, 'pk-c', 'Mac', 1),
      (e: unknown) => e instanceof ApiError && e.code === 'ENTRANCE_LIMIT_REACHED',
      '销毁过的通道不退还额度，第 3 条仍应被拒',
    )
  })
})

test('上限按空间隔离：A 满了不影响 B', async () => {
  await withDb(async () => {
    const a = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-a1', 'iPhone',
    )
    joinSpace(a.joinToken, 'pk-a2', 'Pixel', 1)
    const b = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-b1', 'Mac',
    )
    // B 只登记了创建者这一条 → 仍能加入
    joinSpace(b.joinToken, 'pk-b2', 'iPad', 1)
    assert.equal(entranceCount(b.spaceId), 2, 'B 空间的通道应正常登记')
    assert.equal(entranceCount(a.spaceId), 2)
  })
})

test.after(() => rmSync(configDir, { recursive: true, force: true }))
