/**
 * **头像纳入备份/恢复**回归（2026-09-26）。
 *
 * 背景：头像存在服务端文件里（`avatars/<member_id>`，见 `src/avatars.ts`），
 * 而备份此前只打包 DB + `EINZ_FILES`——**恢复一次备份就把所有人的头像丢掉**。
 * 更早的坑：头像目录默认落在容器内、不在卷里，`--build` 重建容器即清空
 * （见 deployment/docker-compose.*.yml 的 EINZ_AVATARS）。
 *
 * 三条边界：
 *   ① 全量备份带头像，恢复后回来；
 *   ② **不含头像条目的老备份**恢复后，现有头像**不能**被清空（否则比不恢复更糟）；
 *   ③ 单空间备份只带本空间成员头像，恢复不动别人的。
 *
 * 运行：npm test（tsx test/backup_avatars.test.ts）——需要 Node v22
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { openDb } from '../src/db.js'
import { createSpace } from '../src/spaces.js'
import { createBackup, restoreBackup, type BackupPaths } from '../src/backup.js'

/** AVATARS_ROOT 是模块加载期常量（avatars.ts）→ 必须先设 env 再动态 import。 */
const avatarsRoot = mkdtempSync(join(tmpdir(), 'einz-av-bk-'))
const filesRoot = mkdtempSync(join(tmpdir(), 'einz-av-files-'))
process.env.EINZ_AVATARS = avatarsRoot
process.env.EINZ_FILES = filesRoot
process.env.EINZ_DB_BACKUP_KEY = Buffer.alloc(32, 9).toString('base64')
const { storeAvatar, getAvatar } = await import('../src/avatars.js')

/**
 * 每个用例都从**空头像目录**开始。
 * 为什么必须：AVATARS_ROOT 是模块加载期常量（一个进程只能定一次），三个用例共用
 * 同一个目录——不清的话，上一个用例留下的头像文件会让"老备份"里凭空多出
 * avatars/ 条目，②号断言（老备份不该清空现有头像）就会被污染成假失败。
 */
function cleanAvatars (): void {
  rmSync(avatarsRoot, { recursive: true, force: true })
  mkdirSync(avatarsRoot, { recursive: true })
}

function withPaths (fn: (paths: BackupPaths) => Promise<void>): Promise<void> {
  const dataDir = mkdtempSync(join(tmpdir(), 'einz-av-data-'))
  const paths: BackupPaths = {
    db: join(dataDir, 'einz.sqlite.db'),
    files: filesRoot,
    avatars: avatarsRoot,
    dataDir,
  }
  openDb(paths.db)
  return fn(paths).finally(() => rmSync(dataDir, { recursive: true, force: true }))
}

/**
 * [seed] 必须是**合法 base64 的 32 字节**公钥：地址由公钥派生，而 `base64` 解码会
 * 丢掉非法字符——形如 `pk-av3` / `pk-av4` 这种短字符串会被截到同样的字节，
 * 派生出**同一个地址**，第二个空间直接撞 `UNIQUE(space_address)`（踩过）。
 */
async function makeSpace (name: string, seed: number) {
  const publicKey = Buffer.alloc(32, seed).toString('base64')
  return await createSpace(
    undefined, name, 'male', '伴侣', 'female', undefined, undefined, publicKey, 'iPhone',
  )
}

test('全量备份含头像：恢复后头像回来', async () => {
  cleanAvatars()
  await withPaths(async (paths) => {
    const space = await makeSpace('A', 1)
    const bytes = Buffer.from('avatar-bytes-v1', 'utf8')
    const { member_id } = storeAvatar(space.sessionToken, bytes)
    assert.ok(existsSync(join(paths.avatars, member_id)))

    const backup = await createBackup(paths)

    // 破坏现场：把头像删掉（模拟"容器重建/换机器"）
    rmSync(join(paths.avatars, member_id), { force: true })
    assert.equal(getAvatar(member_id), null)

    restoreBackup(backup, paths)
    assert.deepEqual(getAvatar(member_id), bytes)
  })
})

test('不含头像条目的老备份：恢复后现有头像仍在（不被清空）', async () => {
  cleanAvatars()
  await withPaths(async (paths) => {
    const space = await makeSpace('Legacy', 2)
    // 先备份——此刻还没有头像，所以这份备份里没有 avatars/ 条目（等同老版本产物）
    const legacyBackup = await createBackup(paths)

    // 备份之后才设头像
    const bytes = Buffer.from('avatar-set-later', 'utf8')
    const { member_id } = storeAvatar(space.sessionToken, bytes)

    restoreBackup(legacyBackup, paths)

    // 关键断言：老备份恢复不能把"备份之后才设的头像"删掉
    assert.deepEqual(getAvatar(member_id), bytes)
  })
})

test('单空间备份只带本空间成员头像，恢复不动别人的', async () => {
  cleanAvatars()
  await withPaths(async (paths) => {
    const a = await makeSpace('SpaceA', 3)
    const b = await makeSpace('SpaceB', 4)
    const avatarA = storeAvatar(a.sessionToken, Buffer.from('a-avatar', 'utf8'))
    const avatarB = storeAvatar(b.sessionToken, Buffer.from('b-avatar', 'utf8'))

    const backup = await createBackup(paths, a.spaceId)

    // 两份都删掉，再恢复 A 的单空间备份
    rmSync(join(paths.avatars, avatarA.member_id), { force: true })
    rmSync(join(paths.avatars, avatarB.member_id), { force: true })
    restoreBackup(backup, paths)

    assert.deepEqual(getAvatar(avatarA.member_id), Buffer.from('a-avatar', 'utf8'))
    // B 的头像不在 A 的备份里，也不该被这次恢复凭空写出来
    assert.equal(getAvatar(avatarB.member_id), null)
  })
})
