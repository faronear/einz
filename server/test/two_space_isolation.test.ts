/**
 * Multiverse 空间隔离测试（v2-native）。
 *
 * v1 收敛后（2026-09-15）不再有 `/entrances/enroll` + 邀请码那一套：设备登记由
 * `POST /spaces`（创建者）/ `POST /spaces/join`（加入者）一步完成，会话必定绑定
 * 一个 space。本测试因此**只用 v2 入口**搭建两个互不相干的空间。
 *
 * 验证：
 *   1) 消息隔离：A 空间的 /sync 看不到 B 空间的消息，server_sequence 各自独立从 1 起；
 *   2) C1 回归：空间级端点必须持该空间成员会话（join-tokens / key-escrow 上传分支）；
 *   3) C2 回归：/entrances 与 /space 只返回本空间设备；附件读写校验空间归属（含幂等重传）；
 *   4) H4 回归：sessions 表只存 sha256，明文 token 不入库。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）
 */
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
// libsodium-wrappers 的 ESM 入口在 Node ESM 下损坏，统一用 CJS 构建（同 smoke.test.ts）。
const sodium = require('libsodium-wrappers') as typeof import('libsodium-wrappers')
const Database = require('better-sqlite3') as typeof import('better-sqlite3')
const B64 = sodium.base64_variants.ORIGINAL
import { createHash } from 'node:crypto'
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import assert from 'node:assert/strict'

// 所有请求默认带协议版本头（与客户端一致）：服务端对 API 路径做硬校验，
// 缺头/版本不符 → 400 PROTOCOL_VERSION_MISMATCH（PROTOCOL.md §1，2026-09-15 补实现）。
const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': '1', ...(init?.headers as Record<string, string> | undefined) }
  })) as typeof fetch

const ROOT = resolve(import.meta.dirname, '..')

let serverProc: ChildProcess | null = null
let tempDir = ''

function freePort (): Promise<number> {
  return new Promise(done => {
    const srv = createServer()
    srv.listen(0, () => {
      const port = (srv.address() as AddressInfo).port
      srv.close(() => done(port))
    })
  })
}

async function waitReady (port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`)
      void res
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

/** 一个"空间 + 其创建者设备"的最小句柄（v2 入口：POST /spaces 一步登记 + 发会话）。 */
interface SpacePeer {
  spaceId: string
  entranceId: string
  partnerId: string
  sessionToken: string
}

async function createSpace (port: number, label: string): Promise<SpacePeer> {
  const kp = sodium.crypto_box_keypair()
  const res = await fetch(`http://127.0.0.1:${port}/spaces`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      creator_name: label,
      public_key: sodium.to_base64(kp.publicKey, B64),
      entrance_name: label
    })
  })
  assert.equal(res.status, 201, `create ${label} should succeed`)
  const b = (await res.json()) as {
    spaceId: string
    entranceId: string
    creatorPartnerId: string
    sessionToken: string
  }
  assert.ok(b.entranceId.length > 0 && b.sessionToken.length > 0, '创建者应直接拿到设备与会话')
  return {
    spaceId: b.spaceId,
    entranceId: b.entranceId,
    partnerId: b.creatorPartnerId,
    sessionToken: b.sessionToken
  }
}

async function postMessage (port: number, peer: SpacePeer, messageId: string): Promise<number> {
  const res = await fetch(`http://127.0.0.1:${port}/messages`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${peer.sessionToken}`
    },
    body: JSON.stringify({
      v: 1,
      type: 'text',
      key_version: 1,
      message_id: messageId,
      sender_entrance_id: peer.entranceId,
      nonce: 'x',
      ciphertext: 'y'
    })
  })
  assert.equal(res.status, 200, 'post message should succeed')
  return ((await res.json()) as { server_sequence: number }).server_sequence
}

async function sync (
  port: number,
  peer: SpacePeer,
  after: number
): Promise<{ messages: Array<{ message_id: string }>; last_sequence: number }> {
  const res = await fetch(`http://127.0.0.1:${port}/sync?after=${after}`, {
    headers: { Authorization: `Bearer ${peer.sessionToken}` }
  })
  assert.equal(res.status, 200, 'sync should succeed')
  return (await res.json()) as { messages: Array<{ message_id: string }>; last_sequence: number }
}

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-isolation-'))
  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    // EINZ_FILES 必须一并指到临时目录：否则附件会写进 server/data/files/，
    // 上一次运行的 blob 会让下一次上传撞上已有文件（测试必须与仓库状态无关）。
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(tempDir, 'einz.sqlite.db'),
      EINZ_FILES: join(tempDir, 'files')
    },
    stdio: 'ignore'
  })
  await waitReady(port)

  try {
    // 1) 两个互不相干的空间（各自带创建者设备与空间会话）
    const spaceA = await createSpace(port, '空间A')
    const spaceB = await createSpace(port, '空间B')
    assert.notEqual(spaceA.spaceId, spaceB.spaceId, 'two spaces must be distinct')

    // 2) A 在 spaceA 发消息 → sequence 从 1 起
    const seqA1 = await postMessage(port, spaceA, 'a-0001')
    assert.equal(seqA1, 1, 'space A sequence starts at 1')

    // 3) 隔离核心断言：B（spaceB）看不到 A 的消息
    const syncB = await sync(port, spaceB, 0)
    assert.equal(syncB.messages.length, 0, 'Space B must NOT see Space A messages')

    // 4) A 自己能看到自己的消息
    const syncA = await sync(port, spaceA, 0)
    assert.equal(syncA.messages.length, 1, 'Space A sees its own message')
    assert.equal(syncA.messages[0].message_id, 'a-0001')

    // 5) 反向：B 发消息后 A 仍看不到；B 的 sequence 独立从 1 起
    const seqB1 = await postMessage(port, spaceB, 'b-0001')
    assert.equal(seqB1, 1, 'space B sequence starts independently at 1')
    const syncA2 = await sync(port, spaceA, syncA.last_sequence)
    assert.equal(syncA2.messages.length, 0, 'Space A must NOT see Space B messages')
    const syncB2 = await sync(port, spaceB, 0)
    assert.equal(syncB2.messages.length, 1, 'Space B sees its own message')
    assert.equal(syncB2.messages[0].message_id, 'b-0001')

    // ── C1 回归：签发邀请 = 空间级操作，必须持该空间成员会话 ──
    const mintAs = (spaceId: string, token?: string): Promise<Response> =>
      fetch(`http://127.0.0.1:${port}/spaces/${spaceId}/join-tokens`, {
        method: 'POST',
        ...(token ? { headers: { Authorization: `Bearer ${token}` } } : {})
      })
    assert.equal((await mintAs(spaceA.spaceId)).status, 401, '签发邀请未带凭证必须 401')
    assert.equal(
      (await mintAs(spaceB.spaceId, spaceA.sessionToken)).status,
      403,
      'A 不得为 B 的空间签发邀请（跨空间）'
    )
    assert.equal(
      (await mintAs(spaceB.spaceId, spaceB.sessionToken)).status,
      201,
      'B 可为自己的空间签发邀请'
    )

    // ── C1 回归：口令托管包上传必须持该空间成员会话（取包分支免认证，见 smoke）──
    const escrowUpload = (spaceId: string, token?: string): Promise<Response> =>
      fetch(`http://127.0.0.1:${port}/spaces/${spaceId}/key-escrow`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {})
        },
        body: JSON.stringify({
          package: { format: 'backup-v1', salt: 's', nonce: 'n', ciphertext: 'c' },
          passphrase_hash: 'x'
        })
      })
    assert.equal((await escrowUpload(spaceA.spaceId)).status, 401, '上传托管包未带凭证必须 401')
    assert.equal(
      (await escrowUpload(spaceB.spaceId, spaceA.sessionToken)).status,
      403,
      'A 不得覆盖 B 空间的口令托管包（跨空间）'
    )
    assert.equal(
      (await escrowUpload(spaceA.spaceId, spaceA.sessionToken)).status,
      200,
      'A 可上传自己空间的托管包'
    )

    // ── C2 回归：设备列表 / 空间信息只含本空间设备 ──
    const entrancesOf = async (token: string): Promise<string[]> => {
      const res = await fetch(`http://127.0.0.1:${port}/entrances`, {
        headers: { Authorization: `Bearer ${token}` }
      })
      assert.equal(res.status, 200, '/entrances should succeed')
      const body = (await res.json()) as { entrances: Array<{ entrance_id: string }> }
      return body.entrances.map(d => d.entrance_id)
    }
    const devIdsA = await entrancesOf(spaceA.sessionToken)
    assert.ok(devIdsA.includes(spaceA.entranceId), 'A 的 /entrances 应包含自己')
    assert.ok(!devIdsA.includes(spaceB.entranceId), 'A 的 /entrances 不得含 B 空间设备')

    const spaceEntrances = async (token: string): Promise<string[]> => {
      const res = await fetch(`http://127.0.0.1:${port}/space`, {
        headers: { Authorization: `Bearer ${token}` }
      })
      assert.equal(res.status, 200, '/space should succeed')
      const body = (await res.json()) as { entrances: Array<{ entrance_id: string }> }
      return body.entrances.map(d => d.entrance_id)
    }
    const spaceDevA = await spaceEntrances(spaceA.sessionToken)
    assert.ok(!spaceDevA.includes(spaceB.entranceId), '/space 不得含 B 空间设备')

    // ── C2 回归：跨空间附件——A 发消息并挂附件，B 读 404、挂 403 ──
    assert.equal(await postMessage(port, spaceA, 'c0001aaaa'), 2, 'A 第二条消息')

    const blob = Buffer.from('cipher-attachment-blob')
    const sha = createHash('sha256').update(blob).digest('base64')
    const uploadAs = (token: string, attachmentId: string, messageId: string): Promise<Response> =>
      fetch(`http://127.0.0.1:${port}/attachments`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
          Authorization: `Bearer ${token}`,
          'x-attachment-meta': JSON.stringify({
            attachment_id: attachmentId,
            message_id: messageId,
            key_version: 1,
            size: blob.length,
            sha256: sha,
            nonce: 'n'
          })
        },
        body: blob
      })
    const attId = 'aa11bb22cc33dd44'
    const firstUpload = await uploadAs(spaceA.sessionToken, attId, 'c0001aaaa')
    assert.equal(firstUpload.status, 200, 'A 上传自己空间的附件应成功')
    const firstBody = (await firstUpload.json()) as { storage_path: string; created_at: number }
    // 幂等回归：网络抖动后客户端会用**同一个 attachment_id** 重传，必须仍返回 200
    // （此前写盘 flag:"wx" 撞已有文件 → 500），且返回同一条记录
    const retryUpload = await uploadAs(spaceA.sessionToken, attId, 'c0001aaaa')
    assert.equal(retryUpload.status, 200, '同一 attachment_id 重传必须幂等返回 200')
    const retryBody = (await retryUpload.json()) as { storage_path: string; created_at: number }
    assert.equal(retryBody.storage_path, firstBody.storage_path, '幂等重传应返回同一条记录')
    assert.equal(retryBody.created_at, firstBody.created_at, '幂等重传不应刷新 created_at')

    assert.equal(
      (
        await fetch(`http://127.0.0.1:${port}/attachments/${attId}`, {
          headers: { Authorization: `Bearer ${spaceA.sessionToken}` }
        })
      ).status,
      200,
      'A 读自己的附件应成功'
    )
    assert.equal(
      (
        await fetch(`http://127.0.0.1:${port}/attachments/${attId}`, {
          headers: { Authorization: `Bearer ${spaceB.sessionToken}` }
        })
      ).status,
      404,
      'B 读 A 的附件必须 404（不确认存在性）'
    )
    assert.equal(
      (await uploadAs(spaceB.sessionToken, 'ee55ff66aa77bb88', 'c0001aaaa')).status,
      403,
      'B 不得把附件挂到 A 空间的消息上'
    )

    // ── H4 回归：会话只以 sha256 入库，明文不进库 ──
    const sqlite = new Database(join(tempDir, 'einz.sqlite.db'), { readonly: true })
    const sessions = sqlite.prepare(`SELECT session_token FROM sessions`).all() as Array<{
      session_token: string
    }>
    sqlite.close()
    assert.ok(sessions.length > 0, '应有会话行')
    for (const s of sessions) {
      assert.match(s.session_token, /^[0-9a-f]{64}$/, '会话必须以 sha256 十六进制存储')
    }
    assert.ok(
      !sessions.some(s => s.session_token === spaceA.sessionToken),
      '明文 session token 不得入库'
    )

    console.log(
      '✅ 双 Space 隔离测试通过：消息互不可见、sequence 独立、空间级端点鉴权与设备/附件隔离生效、会话只存哈希'
    )
  } finally {
    if (serverProc && serverProc.exitCode === null) serverProc.kill()
    if (tempDir) rmSync(tempDir, { recursive: true, force: true })
  }
}

main()
  .then(() => process.exit(0))
  .catch(err => {
    console.error('❌ 双 Space 隔离测试失败:', err)
    process.exit(1)
  })
