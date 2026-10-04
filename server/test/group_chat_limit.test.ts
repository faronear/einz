// 群聊一期（2026-10-03）**成员上限**回归：serverConfig.json 的 maxMembersPerSpace。
//
// 为什么单独一个文件：config.ts 的配置缓存是**进程级**惰性单例，一个进程里只能
// 加载一份配置。group_chat.test.ts 跑"0=不限"，本文件跑"=2"的受限路径——两个
// 文件由 npm test 分两个进程顺序执行（与 entrance_limit.test.ts 同一手法）。
//
// **2026-10-04 老板拍板取消升格**后，上限的语义收敛成两条互不干扰的规则：
//   · duo  —— 恒 2，**与 maxMembersPerSpace 无关**（双人秘境不是"配置限制"，是定义）
//   · group —— maxMembersPerSpace（0=不限）
// 所以本文件同时验证"group 受配置限制"与"duo 不受配置影响"。
//
// 运行：npm test（tsx test/group_chat_limit.test.ts）——需要 Node v22（better-sqlite3 ABI）
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { createSpace, createJoinToken, getSpaceMode, joinSpace } from '../src/spaces.js'

const configDir = mkdtempSync(join(tmpdir(), 'einz-group-limit-'))
process.env.EINZ_CONFIG = join(configDir, 'serverConfig.json')
writeFileSync(process.env.EINZ_CONFIG, JSON.stringify({ maxMembersPerSpace: 2 }))

async function withDb (fn: () => Promise<void> | void): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-group-limit-'))
  try {
    openDb(join(dir, 'limit.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function create (
  mode: 'duo' | 'group',
  creatorName = '我',
): Promise<{ spaceId: string; joinToken: string; creatorMemberId: string }> {
  return createSpace(
    undefined, creatorName, 'male',
    undefined, undefined, undefined, undefined, undefined, undefined,
    mode,
  )
}

test('group：上限 2 时第三人 join → SPACE_FULL，成员数不涨', async () => {
  await withDb(async () => {
    const space = await create('group')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const invite = createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId)
    assert.throws(
      () => joinSpace(invite.joinToken, 'pk-c', 'Mac', undefined, undefined, '小刚'),
      (e: unknown) => e instanceof ApiError && e.code === 'SPACE_FULL' && e.httpStatus === 409,
    )
    const n = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND member_id IS NOT NULL`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 2, '成员数没变')
  })
})

test('group：上限 2 时第 3 张 invite 仍可签发（签发无副作用），只是 join 会撞上限', async () => {
  await withDb(async () => {
    const space = await create('group')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 签发不做任何空间级副作用（取消升格后），只由 join 时的上限闸兜底
    const invite = createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId)
    assert.ok(invite.joinToken.startsWith('e1_'))
  })
})

test('duo：不受 maxMembersPerSpace 影响——第 2 人可入网（读的是"恒 2"而非配置）', async () => {
  await withDb(async () => {
    const space = await create('duo')
    const b = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.equal(b.slot, 1)
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

test('duo：上限 2 的服务器上，第 3 人照样 DUO_FULL（不是 SPACE_FULL）', async () => {
  await withDb(async () => {
    const space = await create('duo')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const { newJoinToken } = await import('../src/spaces.js')
    const t = newJoinToken(space.spaceId, 'member', 'invite', space.creatorMemberId)
    assert.throws(
      () => joinSpace(t.token, 'pk-c', 'Mac', undefined, undefined, '小刚'),
      (e: unknown) => e instanceof ApiError && e.code === 'DUO_FULL',
      'duo 超员是 DUO_FULL（定义不许），不是 SPACE_FULL（配置不许）',
    )
  })
})
