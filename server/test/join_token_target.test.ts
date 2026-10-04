/**
 * 回归：**定向** join token（target_member_id，2026-10-04）——"只要还有一个安装
 * 存在，空间就永续"。
 *
 * 场景（老板提出）：双人秘境里伴侣丢了手机 / 卸载了 App，她**没有任何安装**可以
 * 自己签发凭证 → 没有这条能力，她就永远回不来、空间作废。于是 attach token 可以
 * 指向**别人**的身份：别的成员把她接回来，她仍在自己的身份上（历史、气泡配色、
 * 别人的认知全都对得上）。
 *
 * 本文件跑的是**HTTP 层**（spawn dist/app.js），因为"对别人的身份动手要共享口令"
 * 这条授权规则的闸门在路由里（app.ts），与"撤销别人通道"同一档：
 *   ① 不带口令 → 400；② 口令错 → 401；③ 口令对 → 201，且拿到的码能把她接回去；
 *   ④ 对自己的身份动手 → 不需要口令（会话即所有权）；
 *   ⑤ duo 满 2 人：invite（开新身份）仍被拒（DUO_FULL），但 attach 永远可用。
 *
 * 运行：npm test（tsx test/join_token_target.test.ts）——需要 Node v22（better-sqlite3 ABI）
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import Database from 'better-sqlite3'

import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

const ROOT = join(import.meta.dirname, '..')
const PASSPHRASE = 'pass12345'

function freePort (): number {
  return 40000 + Math.floor(Math.random() * 20000)
}

async function waitReady (port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`)
      if (res.ok) return
    } catch {}
    await new Promise(r => setTimeout(r, 200))
  }
  throw new Error('server not ready')
}

function req (port: number, path: string, init?: RequestInit): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      'X-Protocol-Version': PROTOCOL_VERSION,
      ...(init?.headers as Record<string, string> | undefined)
    }
  })
}

test('定向 attach：帮别人找回身份（口令授权）+ duo 永续', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-target-'))
  const port = freePort()
  const proc: ChildProcess = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(dir, 'einz.sqlite.db'),
      EINZ_FILES: join(dir, 'files')
    },
    stdio: 'ignore'
  })
  try {
    await waitReady(port)

    // 1) A 建 duo 空间（带头令托管：attach 别人的身份要校验它）
    const create = await req(port, '/spaces', {
      method: 'POST',
      body: JSON.stringify({
        creator_name: '阿蓝',
        creator_gender: 'male',
        escrow_passphrase: PASSPHRASE,
        sealed_space_key: {
          format: 'einz-backup-v1',
          salt: 'c2FsdA==',
          nonce: 'bm9uY2U=',
          ciphertext: 'Y2lwaGVy'
        },
        public_key: 'pk-a'
      })
    })
    assert.equal(create.status, 201, 'create should succeed')
    const a = (await create.json()) as {
      spaceId: string
      joinToken: string
      creatorMemberId: string
      sessionToken: string
    }

    // 2) B 用 invite 码加入（自填名字，落新身份）
    const joinB = await req(port, '/spaces/join', {
      method: 'POST',
      body: JSON.stringify({
        token: a.joinToken,
        public_key: 'pk-b',
        member_name: '小绿',
        member_gender: 'female'
      })
    })
    assert.equal(joinB.status, 200, 'B join should succeed')
    const b = (await joinB.json()) as { memberId: string; slot: number; sessionToken: string }
    assert.notEqual(b.memberId, a.creatorMemberId)
    assert.equal(b.slot, 1)

    const authB = { Authorization: `Bearer ${b.sessionToken}` }
    const issue = (body: Record<string, unknown>): Promise<Response> =>
      req(port, `/spaces/${a.spaceId}/join-tokens`, {
        method: 'POST',
        headers: authB,
        body: JSON.stringify(body)
      })

    // 3) ⑤ duo 满 2 人：开新身份的 invite 被拒（双人秘境不会有第三个人）
    const badInvite = await issue({ purpose: 'invite' })
    assert.equal(badInvite.status, 409, 'duo 满 2 人签不出 invite')
    assert.equal(
      ((await badInvite.json()) as { error: { code: string } }).error.code,
      'DUO_FULL'
    )

    // 4) ① 帮**别人**找回：不带口令 → 400（口令是这条路的授权因子）
    const noPass = await issue({ purpose: 'attach', target_member_id: a.creatorMemberId })
    assert.equal(noPass.status, 400, '对别人的身份动手必须给口令')

    // 5) ② 口令错 → 401
    const wrongPass = await issue({
      purpose: 'attach',
      target_member_id: a.creatorMemberId,
      passphrase: 'wrong-pass'
    })
    assert.equal(wrongPass.status, 401, '口令错必须拒绝')
    assert.equal(
      ((await wrongPass.json()) as { error: { code: string } }).error.code,
      'ESCROW_VERIFY_FAILED'
    )

    // 6) 目标不属于本空间 → 400（且不消耗口令预算：这里连口令都没给）
    const badTarget = await issue({ purpose: 'attach', target_member_id: 'not-a-member' })
    assert.equal(badTarget.status, 400, '目标必须是本空间成员')

    // 7) ③ 口令对 → 201；preflight 报出"这是谁的身份"
    const okRes = await issue({
      purpose: 'attach',
      target_member_id: a.creatorMemberId,
      passphrase: PASSPHRASE
    })
    assert.equal(okRes.status, 201, '口令对应当签出找回链接')
    const target = (await okRes.json()) as { joinToken: string }
    const pre = (await (await req(port, '/spaces/join/preflight', {
      method: 'POST',
      body: JSON.stringify({ token: target.joinToken })
    })).json()) as {
      purpose: string
      targetName: string | null
      targetIsIssuer: boolean
      memberCount: number
      inviterName: string | null
    }
    assert.equal(pre.purpose, 'attach')
    assert.equal(pre.targetName, '阿蓝', 'targetName 应是"要接回的那个人"')
    assert.equal(pre.targetIsIssuer, false, 'target 是别人（不是签发者 B）')
    assert.equal(pre.inviterName, '小绿', 'inviterName 应是签发者 B')
    assert.equal(pre.memberCount, 2)

    // 7b) 签发**不撤销**任何现有通道（2026-10-04 老板要求）：对方没丢设备、只是想在
    // 新设备上再开一条通道时，同样用这个链接——她原来的通道必须原样活着。
    const beforeDb = new Database(join(dir, 'einz.sqlite.db'), { readonly: true })
    const activeBefore = (beforeDb
      .prepare(`SELECT COUNT(*) AS n FROM entrances WHERE status = 'active' AND member_id = ?`)
      .get(a.creatorMemberId) as { n: number }).n
    beforeDb.close()
    assert.equal(activeBefore, 1, '签发前 A 有一条在册通道')

    // 8) A 在新设备（新通道）用它回来：身份仍是原来那个，成员数不变
    const rejoin = await req(port, '/spaces/join', {
      method: 'POST',
      body: JSON.stringify({
        token: target.joinToken,
        public_key: 'pk-a-new-device',
        // 故意**不带** slot（服务端按 target 解析）；也不带名字（身份早就有）
      })
    })
    assert.equal(rejoin.status, 200, 'A 应当能回到自己的身份')
    const back = (await rejoin.json()) as { memberId: string; slot: number; isNewMember: boolean }
    assert.equal(back.memberId, a.creatorMemberId, '必须复用原身份（不是新开一个）')
    assert.equal(back.slot, 0, '还是原来的槽位')
    assert.equal(back.isNewMember, false, '不是新成员（不该广播 member.joined）')

    const db = new Database(join(dir, 'einz.sqlite.db'), { readonly: true })
    const rows = db
      .prepare(`SELECT member_id, status FROM space_members WHERE space_id = ? ORDER BY slot`)
      .all(a.spaceId) as Array<{ member_id: string; status: string }>
    // **旧通道不许被撤销**：A 原来那条（在她"旧设备"上）必须还是 active——
    // 用同一条链接只是"再挂一条新通道"，不是"顶替旧通道"
    const aEntrances = db
      .prepare(`SELECT public_key, status FROM entrances WHERE member_id = ? ORDER BY created_at`)
      .all(a.creatorMemberId) as Array<{ public_key: string; status: string }>
    const bEntrances = db
      .prepare(`SELECT status FROM entrances WHERE member_id = ?`)
      .all(b.memberId) as Array<{ status: string }>
    db.close()
    assert.equal(rows.length, 2, '成员数仍是 2（没有多出一个身份）')
    assert.equal(aEntrances.length, 2, 'A 现在有两条通道（旧 + 新）')
    assert.ok(
      aEntrances.every(e => e.status === 'active'),
      '两条都必须 active——签发/使用找回链接**绝不撤销**对方现有通道'
    )
    assert.ok(aEntrances.some(e => e.public_key === 'pk-a'), 'A 的旧通道还在')
    assert.equal(bEntrances.length, 1)
    assert.equal(bEntrances[0].status, 'active', 'B 的通道不受任何影响')

    // 9) ④ 对自己的身份动手：**不需要**口令（会话即所有权）
    const selfAttach = await issue({ purpose: 'attach', target_member_id: b.memberId })
    assert.equal(selfAttach.status, 201, '自己换设备不需要口令')
    const selfPre = (await (await req(port, '/spaces/join/preflight', {
      method: 'POST',
      body: JSON.stringify({ token: ((await selfAttach.json()) as { joinToken: string }).joinToken })
    })).json()) as { targetIsIssuer: boolean; targetName: string | null }
    assert.equal(selfPre.targetIsIssuer, true)
    assert.equal(selfPre.targetName, '小绿')

    // 10) invite 带 target 属于把两种语义搞混 → 明确 400（不静默忽略）
    const mixed = await issue({ purpose: 'invite', target_member_id: b.memberId })
    assert.equal(mixed.status, 400, 'invite 不能指定目标身份')
  } finally {
    proc.kill()
  }
})
