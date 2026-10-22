/**
 * 服务端转写 `POST /transcriptions`（方案 D'，voiceTranscript.zhcn.md §15.2）单测。
 *
 * 覆盖：
 * 1. wavDurationMs —— 16kHz/16bit/mono 时长计算 + 非 wav/非 PCM 拒绝；
 * 2. parseWhisperStdout —— whisper-cli 时间戳行解析（不依赖 -nt 等新版 flag）；
 * 3. transcribeWav —— 注入假 runner 走通主体（鉴权、日志、返回结构）；
 * 4. realWhisperRunner —— 真 spawn 假引擎脚本（shell 模拟 whisper-cli 读 stdin 出文本），
 *    验证「音频经 stdin 进程内传递、不落盘」的管道路径本身可跑；
 * 5. TRANSCRIBE_DISABLED —— 未配 env 时 503。
 *
 * 运行：npm test（tsx test/transcriptions.test.ts）
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { ApiError, hashSessionToken } from '../src/auth.js'
import { getDb, openDb } from '../src/db.js'
import { parseWhisperStdout, transcribeWav, wavDurationMs } from '../src/transcriptions.js'

const ME_DEVICE = 'dev-me'

/** 16kHz/16bit/单声道 PCM wav（n 毫秒的正弦头部数据即可，头合法就行）。 */
function makeWav (ms: number): Buffer {
  const sampleRate = 16000
  const samples = Math.floor((sampleRate * ms) / 1000)
  const dataLen = samples * 2 // 16bit mono
  const buf = Buffer.alloc(44 + dataLen)
  buf.write('RIFF', 0, 'ascii')
  buf.writeUInt32LE(36 + dataLen, 4)
  buf.write('WAVE', 8, 'ascii')
  buf.write('fmt ', 12, 'ascii')
  buf.writeUInt32LE(16, 16) // fmt chunk size
  buf.writeUInt16LE(1, 20) // PCM
  buf.writeUInt16LE(1, 22) // mono
  buf.writeUInt32LE(sampleRate, 24)
  buf.writeUInt32LE(sampleRate * 2, 28) // byte rate = 16000*2
  buf.writeUInt16LE(2, 32) // block align
  buf.writeUInt16LE(16, 34) // bits
  buf.write('data', 36, 'ascii')
  buf.writeUInt32LE(dataLen, 40)
  return buf
}

function withDb (fn: () => void | Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'einz-transcribe-'))
  const run = async (): Promise<void> => {
    try {
      openDb(join(dir, 't.db'))
      const now = Date.now()
      const db = getDb()
      db.prepare(
        `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
         VALUES ('sp', 'addr', 'pk', ?, ?)`
      ).run(now, now)
      db.prepare(
        `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, created_at)
         VALUES (?, 'member-me', 'pk', 'active', ?, ?)`
      ).run(ME_DEVICE, now, now)
      db.prepare(
        `INSERT INTO space_members (space_id, member_id, slot, status, joined_at)
         VALUES ('sp', 'member-me', 0, 'active', ?)`
      ).run(now)
      db.prepare(
        `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
         VALUES (?, ?, 'sp', ?, ?)`
      ).run(hashSessionToken('tok-me'), ME_DEVICE, now + 3_600_000, now)
      await fn()
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }
  return run()
}

test('wavDurationMs：标准 16kHz PCM wav 算时长；非 wav / 非 PCM 拒绝', () => {
  assert.equal(wavDurationMs(makeWav(1500)), 1500)
  // 带 fact 等额外 chunk 的 wav 也要能算（chunk 遍历容错）
  const withFact = Buffer.concat([
    makeWav(1000).subarray(0, 36),
    Buffer.from('fact'), Buffer.from([4, 0, 0, 0]), Buffer.from([1, 0, 0, 0]),
    makeWav(1000).subarray(36)
  ])
  assert.equal(wavDurationMs(withFact), 1000)

  assert.throws(() => wavDurationMs(Buffer.from('not a wav at all........')), ApiError)
  const nonPcm = makeWav(100); nonPcm.writeUInt16LE(85, 20) // IEEE float
  assert.throws(() => wavDurationMs(nonPcm), /only PCM/)
})

test('parseWhisperStdout：时间戳行取正文、无时间戳行直取、空输出得空串', () => {
  assert.equal(
    parseWhisperStdout('[00:00:00.000 --> 00:00:01.200]  你好世界\n[00:00:01.200 --> 00:00:02.000]  测试'),
    '你好世界 测试'
  )
  assert.equal(parseWhisperStdout('你好世界'), '你好世界')
  assert.equal(parseWhisperStdout(''), '')
  assert.equal(parseWhisperStdout('\n\n'), '')
})

test('transcribeWav：假 runner 走通主体，返回 text + audio_ms', async () => {
  await withDb(async () => {
    const r = await transcribeWav('tok-me', makeWav(2000), 'zh', async () =>
      '[00:00:00.000 --> 00:00:02.000]  转写文本')
    assert.deepEqual(r, { text: '转写文本', audio_ms: 2000 })
  })
})

test('transcribeWav：无效会话 401', async () => {
  await withDb(async () => {
    await assert.rejects(
      transcribeWav('tok-bad', makeWav(100), 'zh', async () => ''),
      (e: ApiError) => e.httpStatus === 401
    )
  })
})

test('realWhisperRunner：真 spawn 假引擎（stdin 管道路径），未配 env 报 TRANSCRIBE_DISABLED', async () => {
  await withDb(async () => {
    // 假引擎：一个 shell 脚本假装 whisper-cli——吃 stdin、吐一行时间戳格式的文本
    const dir = mkdtempSync(join(tmpdir(), 'einz-fake-whisper-'))
    const fakeBin = join(dir, 'fake-whisper-cli.sh')
    writeFileSync(fakeBin, '#!/bin/sh\ncat > /dev/null\necho "[00:00:00.000 --> 00:00:01.000]  假引擎输出"\n')
    chmodSync(fakeBin, 0o755)
    const prevBin = process.env.EINZ_WHISPER_BIN
    const prevModel = process.env.EINZ_WHISPER_MODEL
    process.env.EINZ_WHISPER_BIN = fakeBin
    process.env.EINZ_WHISPER_MODEL = join(dir, 'model.bin')
    try {
      const r = await transcribeWav('tok-me', makeWav(1000), 'zh')
      assert.equal(r.text, '假引擎输出')
      assert.equal(r.audio_ms, 1000)
    } finally {
      if (prevBin === undefined) delete process.env.EINZ_WHISPER_BIN
      else process.env.EINZ_WHISPER_BIN = prevBin
      if (prevModel === undefined) delete process.env.EINZ_WHISPER_MODEL
      else process.env.EINZ_WHISPER_MODEL = prevModel
      rmSync(dir, { recursive: true, force: true })
    }

    // 未配置 env → TRANSCRIBE_DISABLED（503）。注意该检查在 realWhisperRunner 内部
    // （默认 runner 才会触达），因此这里必须用默认 runner，不能注入假的。
    delete process.env.EINZ_WHISPER_BIN
    try {
      await assert.rejects(
        transcribeWav('tok-me', makeWav(100), 'zh'),
        (e: ApiError) => e.code === 'TRANSCRIBE_DISABLED' && e.httpStatus === 503
      )
    } finally {
      if (prevBin === undefined) delete process.env.EINZ_WHISPER_BIN
      else process.env.EINZ_WHISPER_BIN = prevBin
      if (prevModel === undefined) delete process.env.EINZ_WHISPER_MODEL
      else process.env.EINZ_WHISPER_MODEL = prevModel
    }
  })
})
