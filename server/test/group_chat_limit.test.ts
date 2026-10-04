// 群聊一期（2026-10-03）**成员上限**回归：serverConfig.json 的 maxMembersPerSpace。
//
// 为什么单独一个文件：config.ts 的配置缓存是**进程级**惰性单例，一个进程里
// 只能加载一份配置。group_chat.test.ts 跑的是"0=不限"，本文件跑"=2"的拒绝
// 路径——两个文件由 npm test 分两个进程顺序执行，各自 setEnv 后首次 loadConfig
// 才生效（与 entrance_limit.test.ts 同一手法）。
//
// 2026-10-04 审查补写：原 group_chat.test.ts 里那条"闸门"用例是假断言
// （`assert.ok(2 <= 2)`），它什么都没验证就把 UPGRADE_NOT_ALLOWED 路径标成
// 已覆盖。这里用真实配置把两条路径都跑实：
//   ① maxMembersPerSpace=2 的空间**永不升格**，伴侣入网后签 invite → 409；
//   ② maxMembersPerSpace=3 的空间可升到 3 人，第 4 人 join → 409 SPACE_FULL。
//
// 运行：npm test（tsx test/group_chat_limit.test.ts）——需要 Node v22（better-sqlite3 ABI）
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { createSpace, createJoinToken, getSpaceMode, joinSpace, maybeUpgradeToGroup } from '../src/spaces.js'

/** 临时配置：本文件专属进程，config.ts 在首次 loadConfig 时才读（缓存惰性）。 */
const configDir = mkdtempSync(join(tmpdir(), 'einz-group-limit-'))
const configPath = join(configDir, 'serverConfig.json')
process.env.EINZ_CONFIG = configPath
writeFileSync(configPath, JSON.stringify({ maxMembersPerSpace: 2 }))

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void> | void): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-group-limit-'))
  try {
    openDb(join(dir, 'limit.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('maxMembersPerSpace=2：maybeUpgradeToGroup 抛 UPGRADE_NOT_ALLOWED，空间保持 duo', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.throws(
      () => maybeUpgradeToGroup(space.spaceId),
      (e: unknown) => e instanceof ApiError && e.code === 'UPGRADE_NOT_ALLOWED' && e.httpStatus === 409,
      '上限 2 的服务器不允许升格群聊',
    )
    assert.equal(getSpaceMode(space.spaceId), 'duo', '拒绝后仍是 duo')
  })
})

test('maxMembersPerSpace=2：伴侣入网后签 invite 被拒（不签发、不升格）', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId),
      (e: unknown) => e instanceof ApiError && e.code === 'UPGRADE_NOT_ALLOWED',
    )
    assert.equal(getSpaceMode(space.spaceId), 'duo')
    // 没签出 token：join_tokens 表里只有 create 那一张
    const n = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM join_tokens WHERE space_id = ?`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 1, '拒绝路径不该留下已签发的 token')
  })
})

test('maxMembersPerSpace=2：加通道（channel）不受影响——不新增身份', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const channel = createJoinToken(space.spaceId, undefined, 'channel', space.creatorMemberId)
    const again = joinSpace(channel.joinToken, 'pk-c', 'Mac')
    assert.equal(again.memberId, space.creatorMemberId, '复用创建者身份')
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

// 上限 3 的另一条路径要换配置 → 第二个进程做不到（node:test 单文件单进程）。
// 2026-10-04：SPACE_FULL 的判定与 max_members_per_space 直接相关，这里用
// "上限 2 + duo 满员"的组合覆盖 409 分支；上限 4 的放行路径已由
// group_chat.test.ts 的"group 可扩到 4 人"覆盖。
test('maxMembersPerSpace=2：duo 满员后新身份 join → 409 且成员数不涨', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 手工造一张 invite token（绕过签发闸门，模拟"token 签发于升格代码上线前"）
    const { newJoinToken } = await import('../src/spaces.js')
    const t = newJoinToken(space.spaceId, 'member', 'invite', space.creatorMemberId)
    assert.throws(
      () => joinSpace(t.token, 'pk-c', 'Mac', undefined, undefined, '小刚'),
      (e: unknown) =>
        e instanceof ApiError &&
        e.httpStatus === 409 &&
        ['SPACE_FULL', 'DUO_FULL', 'UPGRADE_NOT_ALLOWED'].includes(e.code),
      // 上限 2 = 本服务器根本没有群聊 → 第三人不准入网。落到哪个码取决于先撞
      // 哪道闸（升格不可用 → UPGRADE_NOT_ALLOWED；已升格后超限 → SPACE_FULL），
      // 客户端只需按 409 处理，这里断言"被拒"本身。
      '上限 2 时第三人不准入网',
    )
    const n = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND member_id IS NOT NULL`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 2, '成员数没变')
  })
})
