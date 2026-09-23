/**
 * `install_uid`（安装级标识）回归：多空间下服务端能识别"同一台物理设备"。
 *
 * 背景（老板 2026-09-22 定）：多空间后一台设备在每个空间各有一套独立身份
 * （entrance_id / 公私钥 / entrance_name），这些**故意互不关联**；但服务端需要知道
 * "这几行其实是同一台设备"，于是客户端生成一个安装级 `install_uid`，随
 * create/join 上报，存量通道由 `POST /entrances/install-uid` 幂等补登。
 *
 * 三条边界：① create/join 落库；② 补登幂等、非法输入 400；③ **绝不外泄**——
 * `/space` 与 `/entrances` 的响应体里都不能出现 install_uid（成员之间不可见）。
 *
 * 运行：npm test（tsx test/install_uid.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { listEntrances, setInstallUid } from '../src/entrances.js'
import { getSpace } from '../src/push.js'
import { createSpace, joinSpace } from '../src/spaces.js'

/** 同一台物理设备的标识（32 位 hex，与客户端的生成形状一致）。 */
const UID_D = 'd'.repeat(32)
/** 另一台设备的标识。 */
const UID_E = 'e'.repeat(32)

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-uid-'))
  try {
    openDb(join(dir, 'uid.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function uidOf (entranceId: string): string | null {
  const row = getDb()
    .prepare(`SELECT install_uid FROM entrances WHERE entrance_id = ?`)
    .get(entranceId) as { install_uid: string | null } | undefined
  return row?.install_uid ?? null
}

test('create/join 落库：同一 install_uid 把不同空间的 entrance_id 关联起来', async () => {
  await withDb(async () => {
    // 设备 D 创建空间 A
    const spaceA = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-d', 'iPhone', UID_D,
    )
    // 另一台设备 E 创建空间 B，然后设备 D 用邀请码加入 B（同一个 install_uid）
    const spaceB = await createSpace(
      undefined, '对方', 'female', '伴侣', 'male',
      undefined, undefined, 'pk-e', 'Pixel', UID_E,
    )
    const joined = joinSpace(spaceB.joinToken, 'pk-d2', 'iPhone', 1, UID_D)

    assert.equal(uidOf(spaceA.entranceId), UID_D, 'create 应落 install_uid')
    assert.equal(uidOf(joined.entranceId), UID_D, '同一设备的 join 应落同一个 install_uid')
    assert.equal(uidOf(spaceB.entranceId), UID_E, '另一条通道是另一个 install_uid')

    // 服务端据此能一眼看出"这台物理设备挂了两个空间"
    const rows = getDb()
      .prepare(`SELECT COUNT(DISTINCT entrance_id) AS n FROM entrances WHERE install_uid = ?`)
      .get(UID_D) as { n: number }
    assert.equal(rows.n, 2, '同一 install_uid 下应有两行通道');
  })
})

test('补登：存量行（NULL）由 POST /entrances/install-uid 幂等填上，非法输入 400', async () => {
  await withDb(async () => {
    const space = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-d', 'iPhone', undefined, // 模拟升级前的旧客户端：不带 uid
    )
    assert.equal(uidOf(space.entranceId), null, '不带 install_uid 时留 NULL（不阻断入网）')

    setInstallUid(space.sessionToken, { install_uid: UID_D })
    assert.equal(uidOf(space.entranceId), UID_D, '补登后应写入')

    // 幂等：再调一次不炸、值不变
    setInstallUid(space.sessionToken, { install_uid: UID_D })
    assert.equal(uidOf(space.entranceId), UID_D, '重复补登应幂等')

    for (const bad of [undefined, null, '', 'short', 'x'.repeat(65), 'has space', '有中文']) {
      assert.throws(
        () => setInstallUid(space.sessionToken, { install_uid: bad }),
        (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
        `非法 install_uid 应 400：${String(bad)}`,
      )
    }
    assert.equal(uidOf(space.entranceId), UID_D, '非法输入不得改动已存的值')
  })
})

test('不外泄：/space 与 /entrances 的响应体里都不能出现 install_uid', async () => {
  await withDb(async () => {
    const space = await createSpace(
      undefined, '我', 'male', '伴侣', 'female',
      undefined, undefined, 'pk-d', 'iPhone', UID_D,
    )
    const spaceResult = JSON.stringify(getSpace(space.sessionToken))
    const entrancesResult = JSON.stringify(listEntrances(space.sessionToken))

    for (const [what, body] of [['/space', spaceResult], ['/entrances', entrancesResult]] as const) {
      assert.ok(!body.includes('install_uid'), `${what} 不得返回 install_uid`)
      assert.ok(!body.includes(UID_D), `${what} 不得泄漏 install_uid 的值`)
    }
  })
})
