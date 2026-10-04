/**
 * 回归：`/health` 的**最低 App 版本闸**（2026-10-04）。
 *
 * 服务端在 serverConfig.json 里配 `minAppVersion`（格式 yymm.ddhh.mm）后，/health
 * 多下发 `min_app_version`（+ 可选 `app_download_url`）；客户端启动时据此决定要不要
 * 弹"必须升级"的不可关闭窗口（见 app/lib/widgets/version_gate.dart）。
 *
 * 两条边界：
 *   ① 配了 → 两个字段都出现，值得原样；
 *   ② 没配（或写空串）→ **键根本不出现**（老客户端对未知键无感，但"空值"会让人
 *      以为配了）——这一条同时防"手滑写空串把所有人挡在门外"。
 *
 * 运行：npm test（tsx test/min_app_version.test.ts）——需要 Node v22（better-sqlite3 ABI）
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

const ROOT = join(import.meta.dirname, '..')

function freePort (): number {
  return 41000 + Math.floor(Math.random() * 20000)
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

/** 起一个服务端实例（配置由 config 对象决定），跑完杀掉。 */
async function withServer (
  config: Record<string, unknown>,
  fn: (port: number) => Promise<void>
): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-minapp-'))
  const configPath = join(dir, 'serverConfig.json')
  writeFileSync(configPath, JSON.stringify(config))
  const port = freePort()
  const proc: ChildProcess = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(dir, 'einz.sqlite.db'),
      EINZ_FILES: join(dir, 'files'),
      EINZ_CONFIG: configPath
    },
    stdio: 'ignore'
  })
  try {
    await waitReady(port)
    await fn(port)
  } finally {
    proc.kill()
  }
}

async function health (port: number): Promise<Record<string, unknown>> {
  const res = await fetch(`http://127.0.0.1:${port}/health`, {
    headers: { 'X-Protocol-Version': PROTOCOL_VERSION }
  })
  assert.equal(res.status, 200, '/health 应当 200（免鉴权）')
  return (await res.json()) as Record<string, unknown>
}

test('/health：配了 minAppVersion → 下发 min_app_version + app_download_url', async () => {
  await withServer(
    {
      minAppVersion: '2610.0412.30',
      appDownloadUrl: 'https://example.com/einz/latest'
    },
    async port => {
      const body = await health(port)
      assert.equal(body.min_app_version, '2610.0412.30')
      assert.equal(body.app_download_url, 'https://example.com/einz/latest')
      // 老字段不受影响
      assert.equal(body.status, 'ok')
      assert.ok(Array.isArray(body.capabilities))
    }
  )
})

test('/health：没配（或写空串）→ 两个键都不出现', async () => {
  await withServer({ minAppVersion: '', appDownloadUrl: '   ' }, async port => {
    const body = await health(port)
    assert.ok(
      !('min_app_version' in body),
      '空串一律当作没配——否则手滑写空会把所有客户端挡在门外'
    )
    assert.ok(!('app_download_url' in body), '只有空格也算没配')
  })
})

test('/health：只配 minAppVersion 不配下载链接 → 只下发前者', async () => {
  await withServer({ minAppVersion: '2610.0412.30' }, async port => {
    const body = await health(port)
    assert.equal(body.min_app_version, '2610.0412.30')
    assert.ok(!('app_download_url' in body), '没配链接就不给按钮（客户端只显示版本信息）')
  })
})
