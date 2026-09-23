/**
 * 附件**按空间分片**落盘回归：`data/files/<space_id>/<前2位>/<attachment_id>`。
 *
 * 鉴权早就按 space 隔离（上传校验归属、下载比对 space_id），这里补的是**文件层**——
 * 目的是 per-space 备份/销毁/用量统计（老板 2026-09-23）。
 *
 * 三条边界：① 新上传落在本空间目录；② 两个空间互不串目录；③ 下载仍按库里的
 * storage_path 读（旧规则的行也能读 → 存量无需迁移）。
 *
 * 运行：npm test（tsx test/attachment_space_dir.test.ts）——需要 Node v22
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { openDb } from '../src/db.js'
import { createSpace, joinSpace } from '../src/spaces.js'

/** FILES_ROOT 是模块加载期常量 → 必须在 import attachments 之前设好，故用动态 import。 */
const filesRoot = mkdtempSync(join(tmpdir(), 'einz-files-'))
process.env.EINZ_FILES = filesRoot
const { storeAttachment, getAttachmentBlob, spaceFileDir } = await import('../src/attachments.js')

/** 建一个空库，跑完删掉临时目录。 */
async function withDb (fn: () => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-att-'))
  try {
    openDb(join(dir, 'att.db'))
    await fn()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** 造一个附件（服务端只校验 sha256 与 size，不解密）。 */
function makeBlob (seed: string): { blob: Buffer; sha256: string } {
  const blob = Buffer.from(`blob-${seed}`, 'utf8')
  return { blob, sha256: createHash('sha256').update(blob).digest('base64') }
}

test('新上传落在本空间目录下', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male', '伴侣', 'female', undefined, undefined, 'pk-a', 'iPhone')
    const { blob, sha256 } = makeBlob('one')
    const attachmentId = 'aaaaaaaa-1111-2222-3333-444444444444'
    const stored = storeAttachment(
      space.sessionToken,
      { message_id: 'bbbbbbbb-1111-2222-3333-444444444444', attachment_id: attachmentId, key_version: 1, size: blob.length, sha256, nonce: 'n' },
      blob,
    )
    assert.equal(stored.storage_path, `${space.spaceId}/aa/${attachmentId}`, 'storage_path 应带空间前缀')
    const full = join(filesRoot, stored.storage_path)
    assert.ok(existsSync(full), `文件应落在 ${full}`)
    assert.equal(spaceFileDir(space.spaceId), join(filesRoot, space.spaceId), '空间目录应为 files/<space_id>')
  })
})

test('两个空间的附件各自成目录，互不串', async () => {
  await withDb(async () => {
    const a = await createSpace(undefined, '我', 'male', '伴侣', 'female', undefined, undefined, 'pk-a', 'iPhone')
    const b = await createSpace(undefined, '他', 'male', '伴侣', 'female', undefined, undefined, 'pk-b', 'Pixel')
    const one = makeBlob('a')
    const two = makeBlob('b')
    const idA = 'aaaaaaaa-0000-0000-0000-00000000000a'
    const idB = 'bbbbbbbb-0000-0000-0000-00000000000b'
    storeAttachment(a.sessionToken, { message_id: 'cccccccc-0000-0000-0000-00000000000a', attachment_id: idA, key_version: 1, size: one.blob.length, sha256: one.sha256, nonce: 'n' }, one.blob)
    storeAttachment(b.sessionToken, { message_id: 'dddddddd-0000-0000-0000-00000000000b', attachment_id: idB, key_version: 1, size: two.blob.length, sha256: two.sha256, nonce: 'n' }, two.blob)

    assert.ok(existsSync(join(filesRoot, a.spaceId, 'aa', idA)), 'A 的文件应在 A 目录')
    assert.ok(existsSync(join(filesRoot, b.spaceId, 'bb', idB)), 'B 的文件应在 B 目录')
  })
})

test('下载按库里的 storage_path 读（旧规则的存量行仍可读）', async () => {
  await withDb(async () => {
    const space = await createSpace(undefined, '我', 'male', '伴侣', 'female', undefined, undefined, 'pk-a', 'iPhone')
    const joined = joinSpace(space.joinToken, 'pk-b', 'Pixel', 1)
    const { blob, sha256 } = makeBlob('read')
    const attachmentId = 'cccccccc-2222-3333-4444-555555555555'
    storeAttachment(
      joined.sessionToken,
      { message_id: 'dddddddd-2222-3333-4444-555555555555', attachment_id: attachmentId, key_version: 1, size: blob.length, sha256, nonce: 'n' },
      blob,
    )
    const got = getAttachmentBlob(joined.sessionToken, attachmentId)
    assert.equal(got.toString('utf8'), blob.toString('utf8'), '同空间成员应能读到字节一致的内容')
  })
})

test.after(() => rmSync(filesRoot, { recursive: true, force: true }))
