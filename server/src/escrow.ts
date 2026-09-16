import { getDb } from './db.js'
import { ApiError, resolveSession } from './auth.js'
import { pwhashStrVerify } from './crypto.js'
import { requireSession, requireSpaceMember } from './guard.js'
import { broadcastPassphraseRotated } from './ws.js'

/**
 * 口令托管密钥（KEY_ESCROW.md §4）：Server 只托管"被口令加密的 Space Key 包"，
 * 不解析内容——没有口令（Argon2id 派生）任何人都无法解开。
 * 按 space 存一份（双方同一口令），更新以最新者胜。
 */

export interface EscrowPackage {
  format: string
  salt: string
  nonce: string
  ciphertext: string
}

/** 校验包结构（仅字段类型，不解析内容）。 */
export function parsePackage (raw: unknown): EscrowPackage {
  if (typeof raw !== 'object' || raw === null)
    throw new ApiError('INVALID_REQUEST', 'invalid key-escrow package', 400)
  const p = raw as Record<string, unknown>
  for (const k of ['format', 'salt', 'nonce', 'ciphertext'] as const) {
    if (typeof p[k] !== 'string' || (p[k] as string).length === 0) {
      throw new ApiError(
        'INVALID_REQUEST',
        `invalid key-escrow field: ${k}`,
        400
      )
    }
  }
  return p as unknown as EscrowPackage
}

/**
 * v1 三个 /key-escrow 接口（上传/拉取/删除）共用的"本会话所属空间"。
 *
 * 背景（老板 2026-09-12 报「App 修改口令永远提示『尚未设置口令』」）：Multiverse
 * 的口令密保箱按 **space** 存一份（创建空间时写入 `space_id = <真实 spaceId>`；
 * 加入方从 `POST /spaces/{id}/key-escrow` 取），而 v1 接口此前一律硬编码
 * `space_id = ''` —— 那是一张永远不会被 Multiverse 写入的空行，于是
 * `GET /key-escrow` 恒返回空包，App 改口令/解锁同步/口令重设检测全部失效。
 * `resolveSession` 本来就带 `space_id`，此处直接取用即可（无 space 的 legacy
 * 会话回落 ""，保持旧行为不变）。
 */
function escrowSpaceId (token: string): string {
  return requireSession(token).space_id ?? ''
}

/** POST /key-escrow：上传/更新密文包（UPSERT，按 space 一份）。
 *  可选附 `passphrase_hash`（argon2id）：加入方取包时用它校验口令是否正确
 *  （见 escrowForSpace 的 { passphrase } 分支）。 */
export function uploadKeyEscrow (
  token: string,
  body: unknown
): { ok: true } {
  const { device_id } = requireSession(token)
  const spaceId = escrowSpaceId(token)

  const pkg = parsePackage((body as { package?: unknown })?.package)
  const passphraseHash = (body as { passphrase_hash?: unknown })
    ?.passphrase_hash
  if (
    passphraseHash !== undefined &&
    (typeof passphraseHash !== 'string' || passphraseHash.length === 0)
  ) {
    throw new ApiError('INVALID_REQUEST', 'invalid passphrase_hash', 400)
  }
  // 口令"真正被重设"由客户端显式声明（rotated: true，仅"修改口令"流程发送）。
  // 不可凭 passphrase_hash 比对判定：该哈希是自含随机盐的 argon2id 串
  // （crypto_pwhash_str），同一口令每次上传串都不同，比对必然误判"已重设"。
  // 普通重传（首次设口令/解锁同步等）不得广播，也不得推进 updated_at——
  // 否则对方每次重启解锁都会触发误报（实时广播 + 离线补查双误报）。
  const rotated = (body as { rotated?: unknown })?.rotated === true
  const hasPrev =
    getDb()
      .prepare(`SELECT 1 FROM key_escrow WHERE space_id = ?`)
      .get(spaceId) !== undefined
  if (rotated) {
    // 真正重设：推进 updated_at（离线补查凭它识别）+ 通知其余在线设备
    getDb()
      .prepare(
        `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(space_id) DO UPDATE SET
           package = excluded.package,
           passphrase_hash = excluded.passphrase_hash,
           updated_at = excluded.updated_at`
      )
      .run(spaceId, JSON.stringify(pkg), passphraseHash ?? null, Date.now())
    broadcastPassphraseRotated(device_id)
  } else if (!hasPrev) {
    // 首次托管：写入 updated_at 作为基线（后续真正重设才可对比），不广播
    getDb()
      .prepare(
        `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
         VALUES (?, ?, ?, ?)`
      )
      .run(spaceId, JSON.stringify(pkg), passphraseHash ?? null, Date.now())
  } else {
    // 普通重传（同口令刷新包/哈希）：保留原 updated_at，不广播
    getDb()
      .prepare(
        `UPDATE key_escrow SET package = ?, passphrase_hash = ? WHERE space_id = ?`
      )
      .run(JSON.stringify(pkg), passphraseHash ?? null, spaceId)
  }
  return { ok: true }
}

/** GET /key-escrow：拉取密文包（无包时返回空对象）。 */
export function getKeyEscrow (
  token: string
): { package?: EscrowPackage; updated_at?: number } {
  const { device_id } = requireSession(token)

  const spaceId = escrowSpaceId(token)
  const row = getDb()
    .prepare(`SELECT package, updated_at FROM key_escrow WHERE space_id = ?`)
    .get(spaceId) as { package: string; updated_at: number } | undefined
  return row
    ? {
        package: JSON.parse(row.package) as EscrowPackage,
        updated_at: row.updated_at
      }
    : {}
}

/** DELETE /key-escrow：清除密文包。 */
export function deleteKeyEscrow (
  token: string
): { ok: true } {
  const { device_id } = requireSession(token)

  const spaceId = escrowSpaceId(token)
  getDb().prepare(`DELETE FROM key_escrow WHERE space_id = ?`).run(spaceId)
  return { ok: true }
}


/**
 * 取包口令尝试限速（2026-09-14）：口令是**免设备认证**端点的唯一凭证，无限次尝试
 * 等于允许在线爆破（每次尝试都要跑一遍 argon2id，代价高但可无限重复）。
 * 按 space_id 计失败次数：窗口内超过上限 → 429，直到窗口滑过；成功一次即重置。
 *
 * 阈值可用环境变量覆盖（EINZ_ESCROW_RATE_MAX / EINZ_ESCROW_RATE_WINDOW_MS），
 * 便于测试与运维调参；这是"防在线爆破"，**防不住**拿到 hash 后的离线爆破——
 * 那一层靠口令强度（见 shared/lib/src/crypto/passphrase_policy.dart）。
 */
const ESCROW_RATE_MAX = Number(process.env.EINZ_ESCROW_RATE_MAX ?? 10)
const ESCROW_RATE_WINDOW_MS = Number(
  process.env.EINZ_ESCROW_RATE_WINDOW_MS ?? 15 * 60 * 1000
)
const escrowFailures = new Map<string, number[]>()

function recentFailures (spaceId: string, now: number): number[] {
  const list = (escrowFailures.get(spaceId) ?? []).filter(
    t => now - t < ESCROW_RATE_WINDOW_MS
  )
  if (list.length === 0) escrowFailures.delete(spaceId)
  else escrowFailures.set(spaceId, list)
  return list
}

function assertEscrowNotRateLimited (spaceId: string): void {
  const list = recentFailures(spaceId, Date.now())
  if (list.length >= ESCROW_RATE_MAX) {
    const retryAfterMs = ESCROW_RATE_WINDOW_MS - (Date.now() - list[0])
    throw new ApiError(
      'ESCROW_RATE_LIMITED',
      `too many passphrase attempts, retry after ${Math.ceil(retryAfterMs / 1000)}s`,
      429
    )
  }
}

function recordEscrowFailure (spaceId: string): void {
  const now = Date.now()
  const list = recentFailures(spaceId, now)
  list.push(now)
  escrowFailures.set(spaceId, list)
}

function clearEscrowFailures (spaceId: string): void {
  escrowFailures.delete(spaceId)
}

/**
 * 校验某空间的**密保口令**（argon2id + 同一套失败限速），供"撤销设备"这类敏感操作复用。
 *
 * 为什么复用同一套（而不是各写一份）：
 * - 口令是"销毁本空间某台设备本地数据"的授权凭证，校验强度必须与取钥同级；
 * - 限速窗口按 space 共享（`escrowFailures`）：错误口令的尝试不分来源地计入同一预算，
 *   在空间内被入侵的设备无法靠换端点绕过限速去爆破口令。
 *
 * 失败码与取包分支保持一致，便于客户端统一提示：
 * - 无口令可校验（从未设置 / 被 `DELETE /key-escrow` 清除）→ 409 `PASSPHRASE_NOT_SET`
 *   ——**拒绝而不是放行**：放行等于撤销无需口令，那个洞正是本次要堵的；
 * - 口令错 → 401 `ESCROW_VERIFY_FAILED`（并记一次失败）；
 * - 失败过多 → 429 `ESCROW_RATE_LIMITED`。
 */
export async function assertSpacePassphrase (
  spaceId: string,
  passphrase: unknown
): Promise<void> {
  if (typeof passphrase !== 'string' || passphrase.length === 0) {
    throw new ApiError('INVALID_REQUEST', 'passphrase 必填（撤销设备需校验密保口令）', 400)
  }
  assertEscrowNotRateLimited(spaceId) // 限速：防空间内被入侵设备在线爆破口令
  const row = getDb()
    .prepare(`SELECT passphrase_hash FROM key_escrow WHERE space_id = ?`)
    .get(spaceId) as { passphrase_hash: string | null } | undefined
  if (!row || !row.passphrase_hash) {
    throw new ApiError(
      'PASSPHRASE_NOT_SET',
      '该空间未托管密保口令，无法校验；请先在任一在册设备上设置密保口令',
      409
    )
  }
  if (!(await pwhashStrVerify(row.passphrase_hash, passphrase))) {
    recordEscrowFailure(spaceId)
    throw new ApiError('ESCROW_VERIFY_FAILED', '口令错误', 401)
  }
  clearEscrowFailures(spaceId) // 成功即重置窗口
}

/**
 * Multiverse：按空间读写口令托管包（POST /spaces/{spaceId}/key-escrow，
 * PROTOCOL_MULTIVERSE.md §4.2）：
 * - 上传/更新：{ package, passphrase_hash? }（沿用 v1 upload 语义，按 spaceId 隔离）
 *   ——**必须持该空间成员会话**（2026-09-15 评审 C1：此前任何人拿到 spaceId 就能
 *   覆盖别人的口令托管包与 passphrase_hash，把真实用户顶掉）；
 * - 取包：{ passphrase } → argon2id 校验口令，正确才返回密封包（加入方取钥，
 *   不撤销任何设备、不消耗任何凭证）。
 *
 * 取包分支**刻意保持免认证**：调用方是还没入空间的加入方（它只持口令，尚无
 * session），免认证是这套"口令即凭证"设计的前提；防爆破靠下面的限速。
 */
export async function escrowForSpace (
  token: string | null,
  spaceId: string,
  body: unknown
): Promise<{ ok: true } | { ok: true; package: EscrowPackage }> {
  const sp = getDb()
    .prepare(`SELECT 1 FROM spaces WHERE space_id = ?`)
    .get(spaceId)
  if (!sp) throw new ApiError('SPACE_NOT_FOUND', 'space not found', 404)

  const b = (body ?? {}) as Record<string, unknown>
  if (b.passphrase != null) {
    // 取包：验证口令（口令即"拿到 Space Key 的凭证"）
    assertEscrowNotRateLimited(spaceId) // 限速：防在线爆破（见文件顶部说明）
    const row = getDb()
      .prepare(`SELECT passphrase_hash, package FROM key_escrow WHERE space_id = ?`)
      .get(spaceId) as
      | { passphrase_hash: string | null; package: string | null }
      | undefined
    if (!row || !row.package) {
      throw new ApiError('ESCROW_VERIFY_FAILED', 'no escrow package', 404)
    }
    if (typeof b.passphrase !== 'string' || b.passphrase.length === 0) {
      throw new ApiError('INVALID_REQUEST', 'passphrase 必填', 400)
    }
    if (
      !row.passphrase_hash ||
      !(await pwhashStrVerify(row.passphrase_hash, b.passphrase))
    ) {
      recordEscrowFailure(spaceId) // 记一次失败（限速用）
      throw new ApiError('ESCROW_VERIFY_FAILED', '口令错误', 401)
    }
    clearEscrowFailures(spaceId) // 成功即重置窗口
    return { ok: true, package: JSON.parse(row.package) as EscrowPackage }
  }

  // 上传/更新（UPSERT，最新者胜）
  // 鉴权：必须是该空间成员（见函数头注释；漏挂此校验等于允许任意人顶掉真实用户）
  requireSpaceMember(token, spaceId)
  const pkg = parsePackage(b.package)
  const passphraseHash = b.passphrase_hash
  if (
    passphraseHash !== undefined &&
    (typeof passphraseHash !== 'string' || passphraseHash.length === 0)
  ) {
    throw new ApiError('INVALID_REQUEST', 'invalid passphrase_hash', 400)
  }
  getDb()
    .prepare(
      `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(space_id) DO UPDATE SET
         package = excluded.package,
         passphrase_hash = excluded.passphrase_hash,
         updated_at = excluded.updated_at`
    )
    .run(spaceId, JSON.stringify(pkg), (passphraseHash as string) ?? null, Date.now())
  return { ok: true }
}
