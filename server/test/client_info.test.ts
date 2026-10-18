/**
 * `client`/`app_version`（客户端信息上报）回归：「我的设备通道」卡片/TUI 通道行
 * 要能看出每台设备跑的是 App 还是 TUI、什么版本。
 *
 * 背景（老板 2026-10-14）：per-entrance 的版本号原本想用 key_version——但密钥
 * 轮换不做（entrances.ts 2026-09-14 决策），同一空间所有通道恒同一版本，没有
 * 区分度；真正的 per-entrance 信息是**各设备跑的 App 版本**。于是客户端每次冷
 * 启动经 `POST /entrances/client` 上报：App 报 `{client:'app', app_version}`
 * （升级后下次启动自动跟上），TUI 报 `{client:'tui'}`（AOT 二进制拿不到自身
 * 版本，buildTui.sh 的时间戳只写进产物文件名）。
 *
 * 边界：① 上报落库 + /entrances 带出（**对端可见**——这正是用途）；② 幂等、
 * app_version 只在带值时写（读不到包信息不清掉已存值）；③ 非法输入 400；
 * ④ 存量行/旧客户端 NULL → 不显示该段，不阻断任何流程。
 *
 * 运行：npm test（tsx test/client_info.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { listEntrances, setClientInfo } from '../src/entrances.js'
import { createSpace, joinSpace, createJoinToken } from '../src/spaces.js'

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-client-'))
  try {
    openDb(join(dir, 'client.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function clientInfoOf (entranceId: string): { client: string | null; app_version: string | null } {
  const row = getDb()
    .prepare(`SELECT client, app_version FROM entrances WHERE entrance_id = ?`)
    .get(entranceId) as { client: string | null; app_version: string | null } | undefined
  return { client: row?.client ?? null, app_version: row?.app_version ?? null }
}

/** /entrances 里某条通道的客户端段（显示层口径，同 shared entranceClientLabel）。 */
function clientLabelOf (entranceId: string): string | null {
  const rows = listEntrances(spaceTokenOf(entranceId)).entrances as Array<Record<string, unknown>>
  const row = rows.find(r => r.entrance_id === entranceId)
  const client = row?.client as string | undefined
  if (client === 'tui') return 'TUI'
  if (client === 'app' && typeof row?.app_version === 'string' && row.app_version) {
    return `v${row.app_version as string}`
  }
  return null
}

/** 每条通道各自的 session token（/entrances 只认本会话）。 */
const tokenByEntrance = new Map<string, string>()
function spaceTokenOf (entranceId: string): string {
  const token = tokenByEntrance.get(entranceId)
  assert.ok(token, `测试漏记 token: ${entranceId}`)
  return token
}

test('上报落库 + /entrances 带出：App 带版本、TUI 只带类型（对端可见）', async () => {
  await withDb(async () => {
    // 设备 A（App）创建空间；设备 B（TUI）加入
    const spaceA = await createSpace(undefined, '我', 'male', undefined, undefined, 'pk-a', 'iPhone')
    tokenByEntrance.set(spaceA.entranceId, spaceA.sessionToken)
    const token = createJoinToken(spaceA.spaceId, undefined, 'invite').joinToken
    const joined = joinSpace(token, 'pk-b', 'Terminal')
    tokenByEntrance.set(joined.entranceId, joined.sessionToken)

    // 存量行：没上报过 → NULL，卡片不显示客户端段
    assert.deepEqual(clientInfoOf(spaceA.entranceId), { client: null, app_version: null })
    assert.equal(clientLabelOf(spaceA.entranceId), null)

    // App 上报（client + 版本）
    setClientInfo(spaceA.sessionToken, { client: 'app', app_version: '2610.1409.00' })
    assert.deepEqual(clientInfoOf(spaceA.entranceId), {
      client: 'app',
      app_version: '2610.1409.00',
    })
    assert.equal(clientLabelOf(spaceA.entranceId), 'v2610.1409.00')

    // TUI 上报（只报类型，不带版本）
    setClientInfo(joined.sessionToken, { client: 'tui' })
    assert.deepEqual(clientInfoOf(joined.entranceId), { client: 'tui', app_version: null })
    assert.equal(clientLabelOf(joined.entranceId), 'TUI')

    // 对端可见：B 的列表里能看到 A 的 App 版本，A 的列表里能看到 B 是 TUI
    // （这正是用途——「我的设备通道」里看每台设备跑的什么）
    const fromB = listEntrances(joined.sessionToken).entrances as Array<Record<string, unknown>>
    const rowA = fromB.find(r => r.entrance_id === spaceA.entranceId)
    assert.equal(rowA?.client, 'app')
    assert.equal(rowA?.app_version, '2610.1409.00')
  })
})

test('幂等 + 版本只进不退：只报 client 不带版本时不清掉已存 app_version', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male', undefined, undefined, 'pk-a', 'iPhone')
    tokenByEntrance.set(space.entranceId, space.sessionToken)

    setClientInfo(space.sessionToken, { client: 'app', app_version: '2610.1409.00' })
    // 幂等：重复上报不炸、值不变
    setClientInfo(space.sessionToken, { client: 'app', app_version: '2610.1409.00' })
    assert.equal(clientInfoOf(space.entranceId).app_version, '2610.1409.00')

    // 偶发读不到包信息（只报 client）→ 不清掉已存版本（版本只向前进，
    // 旧值比空值信息量大）；下次带上版本即覆盖
    setClientInfo(space.sessionToken, { client: 'app' })
    assert.equal(clientInfoOf(space.entranceId).app_version, '2610.1409.00',
      '不带 app_version 的上报不得清掉已存版本')
    setClientInfo(space.sessionToken, { client: 'app', app_version: '2610.1509.30' })
    assert.equal(clientInfoOf(space.entranceId).app_version, '2610.1509.30', '升级后应覆盖')
  })
})

test('非法输入 400：client 白名单 + app_version 格式', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male', undefined, undefined, 'pk-a', 'iPhone')
    tokenByEntrance.set(space.entranceId, space.sessionToken)
    setClientInfo(space.sessionToken, { client: 'app', app_version: '2610.1409.00' })

    for (const bad of [undefined, null, '', 'web', 'App', 'TUI', 42]) {
      assert.throws(
        () => setClientInfo(space.sessionToken, { client: bad }),
        (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
        `非法 client 应 400：${String(bad)}`,
      )
    }
    for (const bad of ['2610.1409', '2610140900', 'v2610.1409.00', '2610.14.09.00', '有中文', 42]) {
      assert.throws(
        () => setClientInfo(space.sessionToken, { client: 'app', app_version: bad }),
        (e: unknown) => e instanceof ApiError && e.httpStatus === 400,
        `非法 app_version 应 400：${String(bad)}`,
      )
    }
    // 非法输入不得改动已存的值
    assert.deepEqual(clientInfoOf(space.entranceId), {
      client: 'app',
      app_version: '2610.1409.00',
    })
  })
})
