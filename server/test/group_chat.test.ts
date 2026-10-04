// 群聊一期（2026-10-03）服务端行为：duo/group 双模式、双 purpose token、成员数上限。
//
// **2026-10-04 老板拍板取消升格**：mode 在 create 时定死、永不改变——duo 恒 2 人
//（第 3 个身份一律 DUO_FULL），group 上限看 serverConfig.json 的 maxMembersPerSpace。
// 本文件覆盖"上限不受限（0=不限）"的默认配置；受限配置在 group_chat_limit.test.ts。
//
// 运行：npm test（tsx test/group_chat.test.ts）——需要 Node v22（better-sqlite3 ABI）
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { createSpace, createJoinToken, getSpaceMode, joinSpace, preflightJoin } from '../src/spaces.js'

/** 本文件专属进程：空配置 = 什么都不限（config.ts 首次 loadConfig 时才读）。 */
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

/** createSpace 的参数表很长且是位置参数，包一层省得每处数逗号。 */
function create (
  mode?: 'duo' | 'group',
  creatorName = '我',
): Promise<{ spaceId: string; joinToken: string; creatorMemberId: string }> {
  return createSpace(
    undefined, creatorName, 'male',
    undefined, undefined, undefined, undefined, undefined, undefined,
    mode,
  )
}

test('create 不带 mode → 落 duo（老客户端缺省行为）', async () => {
  await withDb(async () => {
    const space = await create()
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

test('create 带 mode=group → 落 group', async () => {
  await withDb(async () => {
    const space = await create('group')
    assert.equal(getSpaceMode(space.spaceId), 'group')
  })
})

test('create 带非法 mode → 回退 duo（不 500、不落脏值）', async () => {
  await withDb(async () => {
    const space = await createSpace(
      undefined, '我', 'male',
      undefined, undefined, undefined, undefined, undefined, undefined,
      'GROUP' as unknown as 'group', // 大小写/未知值一律回退
    )
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

test('创建不预置伴侣行：只有创建者一个身份', async () => {
  await withDb(async () => {
    const space = await create()
    const n = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ?`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 1, 'v3 起 create 不再预置 slot 1 的伴侣行')
  })
})

test('duo：invite token 不带 slot 开新身份（自填名字），mode 保持 duo', async () => {
  await withDb(async () => {
    const space = await create()
    const joined = joinSpace(
      space.joinToken, 'pk-b', 'Pixel',
      undefined, undefined, '小芳', 'female',
    )
    assert.notEqual(joined.memberId, space.creatorMemberId, '第二人应是新身份')
    assert.equal(joined.slot, 1, '新身份分到最小空 slot')
    assert.equal(joined.isNewMember, true)
    assert.equal(getSpaceMode(space.spaceId), 'duo', 'duo 永远是 duo（无升格）')
  })
})

test('invite token 带 slot → 400（不能指定 slot）', async () => {
  await withDb(async () => {
    const space = await create()
    assert.throws(
      () => joinSpace(space.joinToken, 'pk-b', 'Pixel', 0),
      (e: unknown) => e instanceof ApiError && e.code === 'INVALID_REQUEST',
    )
  })
})

test('attach token：指向自己 = 我在新设备接入（客户端带错的 slot → 403）', async () => {
  await withDb(async () => {
    const space = await create()
    const partner = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 伴侣签 channel token（绑定伴侣身份），尝试冒充创建者 slot 0
    const channel = createJoinToken(space.spaceId, undefined, 'attach', partner.memberId)
    assert.throws(
      () => joinSpace(channel.joinToken, 'pk-c', 'Mac', 0),
      (e: unknown) => e instanceof ApiError && e.httpStatus === 403,
      '带的 slot 与 token 的目标身份不一致 → 403（防错用）',
    )
    // 绑定自己 slot → 放行（成员数不变）
    const own = createJoinToken(space.spaceId, undefined, 'attach', partner.memberId)
    const again = joinSpace(own.joinToken, 'pk-d', 'iPad', partner.slot)
    assert.equal(again.memberId, partner.memberId, '加通道复用同一身份')
    assert.equal(again.isNewMember, false, '加通道不算新成员（不广播 member.joined）')
  })
})

test('duo 满 2 人：签不出 invite（DUO_FULL，且不落 token）', async () => {
  await withDb(async () => {
    const space = await create()
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const before = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM join_tokens WHERE space_id = ?`)
      .get(space.spaceId) as { n: number }).n
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId),
      (e: unknown) => e instanceof ApiError && e.code === 'DUO_FULL' && e.httpStatus === 409,
      '双人秘境里"邀请新成员"是不可能的动作，当场拒绝',
    )
    const after = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM join_tokens WHERE space_id = ?`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(after, before, '拒绝路径不该留下已签发的 token')
  })
})

test('duo 满 2 人：第三人 join（手工造 invite 码）→ DUO_FULL，成员数不变', async () => {
  await withDb(async () => {
    const space = await create()
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    // 绕过签发闸门造一张 invite（模拟"码签发于闸门上线之前"）
    const { newJoinToken } = await import('../src/spaces.js')
    const t = newJoinToken(space.spaceId, 'member', 'invite', space.creatorMemberId)
    assert.throws(
      () => joinSpace(t.token, 'pk-c', 'Mac', undefined, undefined, '小刚'),
      (e: unknown) => e instanceof ApiError && e.code === 'DUO_FULL',
    )
    const n = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND member_id IS NOT NULL`)
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 2, '成员数没变')
    assert.equal(getSpaceMode(space.spaceId), 'duo')
  })
})

test('duo 满 2 人：加通道（channel）不受影响——不新增身份', async () => {
  await withDb(async () => {
    const space = await create()
    joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    const channel = createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId)
    const again = joinSpace(channel.joinToken, 'pk-c', 'Mac')
    assert.equal(again.memberId, space.creatorMemberId, '复用创建者身份')
  })
})

test('group（默认配置 0=不限）：invite 可扩到 4 人，slot 递增', async () => {
  await withDb(async () => {
    const space = await create('group')
    const b = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.equal(b.slot, 1)
    const i2 = createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId)
    const c = joinSpace(i2.joinToken, 'pk-c', 'Mac', undefined, undefined, '小刚')
    assert.equal(c.slot, 2)
    const i3 = createJoinToken(space.spaceId, undefined, 'invite', b.memberId)
    const d = joinSpace(i3.joinToken, 'pk-d', 'iPad', undefined, undefined, '小美')
    assert.equal(d.slot, 3)
    assert.equal(getSpaceMode(space.spaceId), 'group')
  })
})


test('attach 指向**别人**：进入对方的身份（同 memberId/slot，不新增成员）', async () => {
  await withDb(async () => {
    const space = await create()
    const b = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小绿')
    // B 给 A 签发"找回"链接（HTTP 层会额外要求共享口令，这里直接测领域逻辑）
    const recover = createJoinToken(
      space.spaceId, undefined, 'attach', b.memberId, space.creatorMemberId,
    )
    const back = joinSpace(recover.joinToken, 'pk-a-new', 'iPhone')
    assert.equal(back.memberId, space.creatorMemberId, '必须回到 A 自己的身份')
    assert.equal(back.slot, 0, '槽位不变')
    assert.equal(back.isNewMember, false, '不是新成员')
    // 成员数没变；A 的身份名字也没被改（attach 不写名字）
    const row = getDb()
      .prepare(`SELECT display_name FROM space_members WHERE space_id = ? AND slot = 0`)
      .get(space.spaceId) as { display_name: string | null }
    assert.equal(row.display_name, '我')
  })
})

test('attach：目标不属于本空间 → 400；指向不存在的身份 → 400', async () => {
  await withDb(async () => {
    const space = await create()
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId, 'ghost'),
      (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
    )
  })
})

test('invite 带 target → 400（两种语义不能混用，别静默忽略）', async () => {
  await withDb(async () => {
    const space = await create('group')
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'invite', space.creatorMemberId, space.creatorMemberId),
      (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
    )
  })
})

test('attach 必须有目标：self 缺省 = 签发者；两者都没有 → 400', async () => {
  await withDb(async () => {
    const space = await create()
    // 缺省（不传 target）→ 落到签发者自己
    const t1 = createJoinToken(space.spaceId, undefined, 'attach', space.creatorMemberId)
    const pre1 = preflightJoin(t1.joinToken)
    assert.equal(pre1.purpose, 'attach')
    assert.equal(pre1.targetIsIssuer, true)
    assert.equal(pre1.targetName, '我')
    // 签发者与目标都缺 → 400（无法判断进谁的身份）
    assert.throws(
      () => createJoinToken(space.spaceId, undefined, 'attach'),
      (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
    )
  })
})

test('preflight：invite 的 targetName 恒为 null（开新身份，没有"要接回的身份"）', async () => {
  await withDb(async () => {
    const space = await create('group')
    const pre = preflightJoin(space.joinToken)
    assert.equal(pre.purpose, 'invite')
    assert.equal(pre.targetName, null)
    assert.equal(pre.targetIsIssuer, false)
    assert.equal(pre.inviterName, '我')
  })
})

test('存量 pending 行：新身份**复用** slot 1（不留下填不上的幽灵行）', async () => {
  await withDb(async () => {
    const space = await create()
    // 模拟存量库的 pending 行（slot 1, member_id NULL——旧版 create 预置的伴侣位）
    getDb()
      .prepare(
        `INSERT INTO space_members (space_id, member_id, slot, display_name, gender, status, joined_at)
         VALUES (?, NULL, 1, '旧预置', 'female', 'pending', NULL)`,
      )
      .run(space.spaceId)
    const joined = joinSpace(space.joinToken, 'pk-b', 'Pixel', undefined, undefined, '小芳')
    assert.equal(joined.slot, 1, '存量伴侣位就是给伴侣坐的（否则 slot 1 成幽灵行）')
    assert.notEqual(joined.memberId, space.creatorMemberId)
    // 名字归本人：加入者自填的名字覆盖创建者预置的名字
    const row = getDb()
      .prepare(`SELECT display_name, status, member_id FROM space_members WHERE space_id = ? AND slot = 1`)
      .get(space.spaceId) as { display_name: string | null; status: string; member_id: string | null }
    assert.equal(row.display_name, '小芳')
    assert.equal(row.status, 'active')
    assert.ok(row.member_id != null)
    // 只有两位成员：幽灵行没有变成"第三位"
    const n = (getDb()
      .prepare(
        `SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND member_id IS NOT NULL`,
      )
      .get(space.spaceId) as { n: number }).n
    assert.equal(n, 2)
  })
})
