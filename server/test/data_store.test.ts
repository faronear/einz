/**
 * `dataStore` 配置回归（2026-10-07）：serverConfig.json 里能指定 SQLite 文件路径。
 *
 * 背景：工作区经 Seafile 在多机间自动同步，`server/data/einz.sqlite.db` 会被一起同步，
 * 两台机器各写一份 → 冲突副本、库损坏。改用带 `.nosf.` **中缀**的文件名
 * （如 `einz.nosf.sqlite.db`）即可命中全局忽略规则 `*.nosf.*`（连 `-wal`/`-shm`
 * 边车一起被忽略）。但这个命名属个人 Seafile 约定，不该写死进产品默认名 → 做成配置项。
 *
 * 覆盖：
 *   ① 纯函数语义：空/纯空白/非字符串 → 未设；相对路径以**配置文件目录**为基准；绝对原样。
 *   ② 生效：EINZ_CONFIG 指向含 dataStore 的配置 → `openDb()` 在该位置建库。
 *   ③ 优先级：`EINZ_DB` 覆盖 `dataStore`（运行环境注入 > 持久配置）。
 *
 * 运行：npm test（tsx test/data_store.test.ts）——需要 Node v22（better-sqlite3 ABI）
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { after, test } from 'node:test'

import { resolveDataStoreValue } from '../src/configFile.js'
import { openDb } from '../src/db.js'

// ── ① 纯函数语义（不触进程级配置缓存）───────────────────────────────────────

test('resolveDataStoreValue: 空串 / 纯空白 / 非字符串 → undefined（当没配）', () => {
  const cfg = '/srv/config/serverConfig.json'
  assert.equal(resolveDataStoreValue(undefined, cfg), undefined)
  assert.equal(resolveDataStoreValue('', cfg), undefined)
  assert.equal(resolveDataStoreValue('   ', cfg), undefined)
  assert.equal(resolveDataStoreValue(42, cfg), undefined)
})

test('resolveDataStoreValue: 相对路径以配置文件所在目录为基准（不是 cwd）', () => {
  assert.equal(
    resolveDataStoreValue('../data/einz.nosf.sqlite.db', '/srv/config/serverConfig.json'),
    resolve('/srv/config/../data/einz.nosf.sqlite.db'), // = /srv/data/einz.nosf.sqlite.db
  )
})

test('resolveDataStoreValue: 绝对路径原样保留', () => {
  assert.equal(
    resolveDataStoreValue('/var/lib/einz/einz.nosf.sqlite.db', '/srv/config/serverConfig.json'),
    '/var/lib/einz/einz.nosf.sqlite.db',
  )
})

// ── ②③ 生效与优先级（真实建库，都在临时目录内，绝不碰真实数据）─────────────

const DIR = mkdtempSync(join(tmpdir(), 'einz-datastore-'))
const CONFIG_PATH = join(DIR, 'config', 'serverConfig.json')
mkdirSync(join(DIR, 'config'), { recursive: true })
writeFileSync(CONFIG_PATH, JSON.stringify({ dataStore: '../data/einz.nosf.sqlite.db' }))
// 本文件专属进程：configFile 的缓存在首次读取时定型，必须在此之前设好 EINZ_CONFIG。
process.env.EINZ_CONFIG = CONFIG_PATH
delete process.env.EINZ_DB // 让 dataStore 成为生效来源

after(() => rmSync(DIR, { recursive: true, force: true }))

/** dataStore = "../data/einz.nosf.sqlite.db" 相对 DIR/config/ → DIR/data/ */
const EXPECTED = resolve(join(DIR, 'data', 'einz.nosf.sqlite.db'))

test('openDb(): 未设 EINZ_DB 时，按 dataStore 的相对路径建库', () => {
  openDb()
  assert.ok(existsSync(EXPECTED), `应在 ${EXPECTED} 建库`)
  // 没有误落到内置默认（server/data）或其它位置
  assert.ok(!existsSync(join(DIR, 'config', 'data', 'einz.nosf.sqlite.db')))
})

test('openDb(): EINZ_DB 优先于 dataStore（运行时覆盖 > 持久配置）', () => {
  const override = join(DIR, 'override.db')
  process.env.EINZ_DB = override
  try {
    openDb()
    assert.ok(existsSync(override), 'EINZ_DB 应覆盖 dataStore')
  } finally {
    delete process.env.EINZ_DB
  }
})
