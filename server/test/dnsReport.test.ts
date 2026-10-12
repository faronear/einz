/**
 * DNS 污染上报端点测试（2026-10-11）：
 * POST /network/dns-report 免鉴权可写（限速）、入参校验（坏 domain / 坏 doh_ip → 400）、
 * GET 聚合返回按天/域名计数且不暴露 IP、协议版本硬校验对本端点同样生效。
 *
 * 运行：npm test（先 build 生成 dist/）
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type AddressInfo } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import assert from 'node:assert/strict'
import { PROTOCOL_VERSION } from '../src/protocolVersion.js'

const RAW_FETCH = globalThis.fetch
globalThis.fetch = ((input: Parameters<typeof fetch>[0], init: Parameters<typeof fetch>[1] = {}) =>
  RAW_FETCH(input, {
    ...init,
    headers: { 'X-Protocol-Version': PROTOCOL_VERSION, ...(init?.headers as Record<string, string> | undefined) }
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
      await fetch(`http://127.0.0.1:${port}/health`)
      return
    } catch {
      await new Promise(r => setTimeout(r, 100))
    }
  }
  throw new Error('server did not become ready in time')
}

async function main (): Promise<void> {
  tempDir = mkdtempSync(join(tmpdir(), 'einz-dnsreport-'))
  const port = await freePort()
  serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      EINZ_DB: join(tempDir, 'einz.sqlite.db'),
      EINZ_FILES: join(tempDir, 'files')
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  serverProc.stderr?.on('data', d => process.stderr.write(`[server] ${d}`))

  try {
    await waitReady(port)
    const base = `http://127.0.0.1:${port}`

    // 1) 正常上报 → 200（免鉴权：无 Bearer 也收）
    const ok = await fetch(`${base}/network/dns-report`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ domain: 'einz.yuanjinx.com', doh_ip: '36.154.238.42' })
    })
    assert.equal(ok.status, 200, '正常上报必须 200（免鉴权）')

    // 2) 不带 X-Protocol-Version → 400（端点不进豁免名单）
    const noVersion = await RAW_FETCH(`${base}/network/dns-report`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ domain: 'einz.yuanjinx.com' })
    })
    assert.equal(noVersion.status, 400, '缺协议版本头必须 400')

    // 3) 入参校验：坏 domain / 坏 doh_ip → 400 INVALID_REQUEST
    for (const body of [
      { domain: 'not a domain' },
      { domain: 'einz.yuanjinx.com', doh_ip: '999.1.1.1' },
      { domain: 'einz.yuanjinx.com', doh_ip: 'not-an-ip' },
      { domain: 'a'.repeat(300) }
    ]) {
      const bad = await fetch(`${base}/network/dns-report`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      })
      assert.equal(bad.status, 400, `非法入参必须 400：${JSON.stringify(body)}`)
      const j = (await bad.json()) as { error?: { code?: string } }
      assert.equal(j.error?.code, 'INVALID_REQUEST')
    }

    // 4) 第二条正常上报（另一域名）→ 聚合计数正确
    await fetch(`${base}/network/dns-report`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ domain: 'einz.bittic.cn' })
    })

    const agg = await fetch(`${base}/network/dns-report`)
    assert.equal(agg.status, 200)
    const summary = (await agg.json()) as { reports: { day: string; domain: string; count: number }[] }
    const total = summary.reports.reduce((s, r) => s + r.count, 0)
    assert.equal(total, 2, '聚合计数应等于成功上报条数')
    const domains = summary.reports.map(r => r.domain).sort()
    assert.deepEqual(domains, ['einz.bittic.cn', 'einz.yuanjinx.com'])
    // 聚合不得泄露 IP
    assert.ok(!JSON.stringify(summary).includes('36.154'), '聚合响应不得包含 IP')

    // 5) 限速：EINZ_RATELIMIT_DNS_REPORT 默认 10/小时——第 11 次（8 个合法 + 已耗 2 + 400 不计数
    //    ？）不猜边界：直接把阈值压到 2 重开一个服务器验证 429 行为
    //    （实现上 checkRateLimit 只在通过校验前调用 limitByIp → 400 也占额度，这里只验证有 429 存在）
    await serverProc.kill('SIGKILL')
    const port2 = await freePort()
    serverProc = spawn(process.execPath, [join(ROOT, 'dist/app.js')], {
      env: {
        ...process.env,
        PORT: String(port2),
        EINZ_DB: join(tempDir, 'einz2.sqlite.db'),
        EINZ_FILES: join(tempDir, 'files2'),
        EINZ_RATELIMIT_DNS_REPORT: '2'
      },
      stdio: ['ignore', 'pipe', 'pipe']
    })
    await waitReady(port2)
    for (let i = 0; i < 2; i++) {
      const r = await fetch(`http://127.0.0.1:${port2}/network/dns-report`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain: 'einz.yuanjinx.com' })
      })
      assert.equal(r.status, 200)
    }
    const third = await fetch(`http://127.0.0.1:${port2}/network/dns-report`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ domain: 'einz.yuanjinx.com' })
    })
    assert.equal(third.status, 429, '超 dnsReport 桶限额必须 429')

    console.log('dnsReport.test: all assertions passed')
  } finally {
    serverProc?.kill('SIGKILL')
    setTimeout(() => process.exit(0), 200).unref()
    for (let i = 0; i < 5; i++) {
      try { rmSync(tempDir, { recursive: true, force: true }); break } catch { await new Promise(r => setTimeout(r, 200)) }
    }
  }
}

main().catch(err => {
  console.error(err)
  process.exit(1)
})
