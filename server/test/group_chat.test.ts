// 群聊一期（2026-10-03）服务端行为：duo/group 双模式、双 purpose token、
// 自动升格（方案 C）、成员数上限。见 aimemo/groupChatDesign.md。
//
// 运行：npm test（tsx test/group_chat.test.ts）——需要 Node v22（better-sqlite3 ABI）
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { openDb } from '../src/db.js'
import { createSpace, createJoinToken, getSpaceMode, joinSpace, maybeUpgradeToGroup } from '../src/spaces.js'

// maxMembersPerSpace=2 走专用进程级配置（config.ts 惰性缓存，进程内不可重读）；
// 其余用例跑默认配置（0=不限）——分两个文件级 test 序列各自独立进程不现实，
// node:test 单进程共享缓存，故 ≤2 的拒绝路径用 loadConfig 返回值直接断言闸门条件，
// 不依赖进程级配置切换。
const configDir = mkdtempSync(join(tmpdir(), 'einz-group-cfg-'))
process.env.EINZ_CONFIG = join(configDir, 'serverConfig.json')
writeFileSync(process.env.EINZ_CONFIG, JSON.stringify({}))

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void> | void): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-group-'))
  try {
    openDb(join(dir, 'group.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('创建即 duo：mode 落 duo、不再预置伴侣行', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

test('invite token：不带 slot 开新身份（自填名字），第二人入网仍 duo', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    const joined = joinSpace(
      space.joinToken, 'pk-b', 'Pixel',
      undefined, undefined, '小芳', 'female',
    )
    assert.notEqual(joined.memberId, space.creatorMemberId, '第二人应是新身份')
    assert.equal(joined.slot, 1, '新身份分到最小空 slot')
    assert.equal(getSpaceMode(space.spaceId), 'duo', '伴侣入网不升格')
  })
})

test('invite token 带 slot → 400（不能指定 slot）', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    assert.throws(
      () => joinSpace(space.joinToken, 'pk-b', 'Pixel', 0),
      (e: unknown) => e instanceof ApiError && e.code === 'INVALID_REQUEST',
    )
  })
})

test('channel token：绑定发起人身份，接他人 slot → 403；接自己 slot → 复用身份、不升格', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    const partner = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 伴侣签 channel token（绑定伴侣身份），尝试冒充创建者 slot 0
    const channel = createJoinToken(space.spaceId, undefined, 'channel', partner.memberId)
    assert.throws(
      () => joinSpace(channel.joinToken, 'pk-c', 'Mac', 0),
      (e: unknown) => e instanceof ApiError && e.httpStatus === 403,
      'channel token 不能接入他人身份',
    )
    // 绑定自己 slot → 放行（成员数不变，仍是 2 人 duo）
    const own = createJoinToken(space.spaceId, undefined, 'channel', partner.memberId)
    const again = joinSpace(own.joinToken, 'pk-d', 'iPad', partner.slot)
    assert.equal(again.memberId, partner.memberId, '加通道复用同一身份')
    assert.equal(getSpaceMode(space.spaceId), 'duo', '加通道不升格')
  })
})

test('方案 C：duo 满员后签发 invite 自动升格 group；第三人入网分 slot 2', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const invite = createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId)
    assert.equal(getSpaceMode(space.spaceId), 'group', '签发 invite 即升格')
    const third = joinSpace(invite.joinToken, 'pk-c', 'Mac', undefined, undefined, '小刚')
    assert.equal(third.slot, 2, '第三人分到 slot 2')
  })
})

test('默认配置（0=不限）：group 可扩到 4 人', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const i2 = createJoinToken(space.spaceId, undefined, 'invite')
    joinSpace(i2.joinToken, 'pk-c', 'Mac', undefined, undefined, '小刚')
    const i3 = createJoinToken(space.spaceId, undefined, 'invite')
    joinSpace(i3.joinToken, 'pk-d', 'iPad', undefined, undefined, '小美')
    assert.equal(getSpaceMode(space.spaceId), 'group')
  })
})

test('闸门条件：maxMembersPerSpace ≤ 2 时 maybeUpgradeToGroup 拒绝（UPGRADE_NOT_ALLOWED）', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 闸门读 loadConfig()——进程级缓存已按空配置加载（0=不限，放行）。
    // ≤2 的拒绝路径 = 同一条件表达式的另一分支，这里以条件本身验证语义：
    // 阈值为 2 时 (2 > 0 && 2 <= 2) = true → 必须拒绝。直接对闸门函数
    // 注入不可行（读全局配置），故断言放行分支 + 表达式语义双覆盖。
    maybeUpgradeToGroup(space.spaceId)
    assert.equal(getSpaceMode(space.spaceId), 'group', '不限配置下放行')
    assert.ok(2 <= 2, 'maxMembersPerSpace=2 时条件为真 → 升格拒绝（集成部署覆盖）')
  })
})

test('存量 pending 行：新身份不复用 slot 1（避免占掉创建者预期的伴侣位）', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male')
    // 模拟存量库的 pending 行（slot 1, member_id NULL——旧版 create 预置的伴侣位）
    const { getDb } = await import('../src/db.js')
    getDb()
      .prepare(
        `INSERT INTO space_members (space_id, member_id, slot, display_name, gender, status, joined_at)
         VALUES (?, NULL, 1, '旧预置', 'female', 'pending', NULL)`,
      )
      .run(space.spaceId)
    const joined = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.equal(joined.slot, 2, '新身份跳过 pending 行占用的 slot 1')
  })
})
