/**
 * **单空间备份/恢复**回归（老板 2026-09-23 选 A 方案）：
 * `createBackup(paths, spaceId)` 只导出该空间的行 + `files/<space_id>/`；
 * 恢复时只覆盖该空间，**别的空间与库文件都不动**（区别于全量恢复的"删库 + 清 files/"）。
 *
 * 三条边界：① 备份只含本空间的文件；② 恢复后本空间数据回来；③ 别的空间毫发无损。
 *
 * 运行：npm test（tsx test/backup_space.test.ts）——需要 Node v22
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { getDb, openDb } from '../src/db.js'
import { createSpace } from '../src/spaces.js'
import { createBackup, restoreBackup, verifyBackup, type BackupPaths } from '../src/backup.js'

/** FILES_ROOT 是模块加载期常量 → 先设 env 再动态 import。 */
const filesRoot = mkdtempSync(join(tmpdir(), 'einz-bk-files-'))
process.env.EINZ_FILES = filesRoot
process.env.EINZ_DB_BACKUP_KEY = Buffer.alloc(32, 7).toString('base64')
const { storeAttachment } = await import('../src/attachments.js')

/** 建一套临时 data 目录（库 + files + backups），跑完删掉。 */
function withPaths (fn: (paths: BackupPaths) => Promise<void>): Promise<void> {
  const dataDir = mkdtempSync(join(tmpdir(), 'einz-bk-data-'))
  const paths: BackupPaths = {
    db: join(dataDir, 'einz.sqlite.db'),
    files: filesRoot,
    dataDir,
  }
  openDb(paths.db)
  return fn(paths).finally(() => rmSync(dataDir, { recursive: true, force: true }))
}

/** 建一个空间并上传一个附件，返回空间 id 与 attachment_id。 */
async function makeSpaceWithAttachment (name: string, seed: string) {
  const space = await createSpace(undefined, name, 'male', '伴侣', 'female', undefined, undefined, `pk-${seed}`, 'iPhone')
  const blob = Buffer.from(`blob-${seed}`, 'utf8')
  const attachmentId = `${seed}aaaaaaa-1111-2222-3333-444444444444`
  storeAttachment(
    space.sessionToken,
    {
      message_id: `${seed}bbbbbbb-1111-2222-3333-444444444444`,
      attachment_id: attachmentId,
      key_version: 1,
      size: blob.length,
      sha256: createHash('sha256').update(blob).digest('base64'),
      nonce: 'n',
    },
    blob,
  )
  return { spaceId: space.spaceId, attachmentId }
}

test('单空间备份：只含本空间的文件，恢复只覆盖本空间', async () => {
  await withPaths(async (paths) => {
    const a = await makeSpaceWithAttachment('我', 'aaaa1111')
    const b = await makeSpaceWithAttachment('他', 'bbbb2222')
    const fileA = join(paths.files, a.spaceId, 'aa', a.attachmentId)
    const fileB = join(paths.files, b.spaceId, 'bb', b.attachmentId)
    assert.ok(existsSync(fileA) && existsSync(fileB), '两个空间的附件都应已落盘')

    const backup = await createBackup(paths, a.spaceId)
    const info = verifyBackup(backup)
    assert.equal(info.scope.type, 'space')
    assert.equal(info.scope.space_id, a.spaceId)
    assert.ok(info.entries.every((p) => p.startsWith(`files/${a.spaceId}/`)), '备份里不得出现别的空间的文件')

    // 制造"本空间数据丢失"：删 A 的行与文件目录
    getDb().prepare(`DELETE FROM attachments WHERE space_id = ?`).run(a.spaceId)
    getDb().prepare(`DELETE FROM messages WHERE space_id = ?`).run(a.spaceId)
    rmSync(join(paths.files, a.spaceId), { recursive: true, force: true })
    assert.equal(existsSync(fileA), false, 'A 的文件应已被删')

    restoreBackup(backup, paths)

    // A 回来
    assert.equal(existsSync(fileA), true, 'A 的附件文件应被恢复')
    const rowsA = getDb().prepare(`SELECT COUNT(*) AS n FROM attachments WHERE space_id = ?`).get(a.spaceId) as { n: number }
    assert.equal(rowsA.n, 1, 'A 的附件行应被恢复')
    // B 毫发无损
    assert.equal(existsSync(fileB), true, 'B 的文件不得被动过')
    const rowsB = getDb().prepare(`SELECT COUNT(*) AS n FROM attachments WHERE space_id = ?`).get(b.spaceId) as { n: number }
    assert.equal(rowsB.n, 1, 'B 的附件行不得被动过')
    const spaceCount = getDb().prepare(`SELECT COUNT(*) AS n FROM spaces`).get() as { n: number }
    assert.equal(spaceCount.n, 2, '两个空间都还在')
  })
})

test('全量备份不受影响：scope=all 且含整库条目', async () => {
  await withPaths(async (paths) => {
    await makeSpaceWithAttachment('我', 'cccc3333')
    const backup = await createBackup(paths)
    const info = verifyBackup(backup)
    assert.equal(info.scope.type, 'all')
    assert.ok(info.entries.includes('app.db'), '全量备份应带整库条目')
  })
})

test.after(() => rmSync(filesRoot, { recursive: true, force: true }))
