/**
 * 回归：用户名称（member 显示名）规则（老板 2026-09-16 定）——最多 32 字符，
 * 只允许中文字 / 英文字母 / 数字 / `_` `-` / emoji。
 *
 * 与通道名（entrance_name.test.ts）的差别是**允许 emoji**：名字是给人看的亲昵称呼。
 * 名字一律由用户输入（没有自动取名这条路），所以服务端只做**拒绝**（400），
 * 不做消毒——静默改写人的名字等于名字莫名变了。
 *
 * 客户端同款规则在 shared/lib/src/policy/member_name_policy.dart（改动请同步）。
 *
 * 运行：npm test（tsx test/member_name.test.ts）
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError } from '../src/auth.js'
import { assertMemberName } from '../src/memberName.js'
import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

const ROOT = join(import.meta.dirname, '..')

function freePort (): number {
  return 42000 + Math.floor(Math.random() * 20000)
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
    headers: { 'X-Protocol-Version': PROTOCOL_VERSION, ...(init?.headers as Record<string, string> | undefined) }
  })
}

test('assertMemberName：合规放行（含 emoji），不合规 400', () => {
  // 𠮷 = 扩展 B 汉字（罕见姓名用字，老板 2026-09-16 要求放行）
  for (const ok of ['Lukas', '小猪🐷', 'a_张-1', '😀', '🇨🇳', '👨‍👩‍👧', '❤️', '✨', '𠮷', '㐀', 'a'.repeat(32)]) {
    assert.doesNotThrow(() => assertMemberName(ok), `应放行: ${ok}`)
  }
  // 空格、中文标点、@、全角字母、超长 —— 都不合规
  // 假名 / 谚文 / 全角字母不是汉字，仍拒
  for (const bad of ['', '   ', 'Mr Lukas', '名字。', 'a@b', 'Ｌｕｋａｓ', 'あ', '한', 'Ａ', 'a'.repeat(33), '😀'.repeat(33)]) {
    assert.throws(
      () => assertMemberName(bad),
      (e: unknown) => e instanceof ApiError && e.code === 'INVALID_REQUEST',
      `应拒收: ${JSON.stringify(bad)}`
    )
  }
})

test('端到端：create 的创建者名、join 的自填名、改名都按白名单收口', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'einz-member-'))
  const port = freePort()
  const proc: ChildProcess = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: { ...process.env, PORT: String(port), EINZ_DB: join(dir, 'einz.sqlite.db'), EINZ_FILES: join(dir, 'files') },
    stdio: 'ignore'
  })
  try {
    await waitReady(port)

    // 1) create：创建者名字含空格 → 400（名字是用户输入的，只拒收不消毒）
    //    v3（2026-10-03）起 create **只录创建者**——不再有 peer_name，
    //    "两人同名"这类与"按名字选身份"绑定的旧规则随之作废。
    const createWith = async (creatorName: string): Promise<number> => {
      const res = await req(port, '/spaces', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          creator_name: creatorName,
          public_key: Buffer.alloc(32, 7).toString('base64')
        })
      })
      return res.status
    }
    assert.equal(await createWith('Mr Lukas'), 400, '我的名字含空格应被拒')
    assert.equal(await createWith('a'.repeat(33)), 400, '超长名字应被拒')

    // 2) create：合规名字（含 emoji）→ 201
    const create = await req(port, '/spaces', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        creator_name: '小猪🐷',
        public_key: Buffer.alloc(32, 7).toString('base64')
      })
    })
    assert.equal(create.status, 201, '合规名字应创建成功')
    const created = (await create.json()) as { sessionToken: string; joinToken: string }
    const { sessionToken } = created
    const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${sessionToken}` }

    const space = (await (await req(port, '/space', { headers: auth })).json()) as {
      member_names: Record<string, string>
    }
    assert.ok(Object.values(space.member_names).includes('小猪🐷'), 'emoji 名字应原样入库')

    // 2b) join 的自填名字同样收口（2026-10-04 补的服务端校验——此前只有 create
    //     在拦，CLI/手搓请求能塞进任意串）。带空格 → 400。
    const joinWith = async (memberName: string): Promise<number> => {
      const res = await req(port, '/spaces/join', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: created.joinToken,
          public_key: Buffer.alloc(32, 8).toString('base64'),
          member_name: memberName,
          member_gender: 'female'
        })
      })
      return res.status
    }
    assert.equal(await joinWith('My Love'), 400, '加入者自填名含空格应被拒')
    assert.equal(await joinWith('阿猪🐷_01'), 200, '合规名字应能加入')

    // 3) 改名：不合规 400；合规（emoji）200 生效
    for (const bad of ['Mr Lukas', '名字。', 'a'.repeat(33)]) {
      const res = await req(port, '/members/name', {
        method: 'POST',
        headers: auth,
        body: JSON.stringify({ member_name: bad })
      })
      assert.equal(res.status, 400, `不合规改名应被拒: ${bad}`)
    }
    const ok = await req(port, '/members/name', {
      method: 'POST',
      headers: auth,
      body: JSON.stringify({ member_name: '阿猪🐷_01' })
    })
    assert.equal(ok.status, 200, '合规改名应成功')
    const space2 = (await (await req(port, '/space', { headers: auth })).json()) as {
      member_names: Record<string, string>
    }
    assert.ok(Object.values(space2.member_names).includes('阿猪🐷_01'), '改名应生效')
  } finally {
    proc.kill()
  }
})
