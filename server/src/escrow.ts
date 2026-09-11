import { getDb } from './db.js'
import { ApiError, resolveSession } from './auth.js'
import { isActiveDevice, type ServerConfig } from './config.js'
import { pwhashStrVerify } from './crypto.js'
import { broadcastPassphraseRotated, notifyRevoked } from './ws.js'

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

/** POST /key-escrow：上传/更新密文包（UPSERT，按 space 一份）。
 *  可选附 `passphrase_hash`（argon2id，恢复接口 /recover 校验口令用）。 */
export function uploadKeyEscrow (
  cfg: ServerConfig,
  token: string,
  body: unknown
): { ok: true } {
  const { device_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

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
      .get("") !== undefined
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
      .run("", JSON.stringify(pkg), passphraseHash ?? null, Date.now())
    broadcastPassphraseRotated(device_id)
  } else if (!hasPrev) {
    // 首次托管：写入 updated_at 作为基线（后续真正重设才可对比），不广播
    getDb()
      .prepare(
        `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
         VALUES (?, ?, ?, ?)`
      )
      .run("", JSON.stringify(pkg), passphraseHash ?? null, Date.now())
  } else {
    // 普通重传（同口令刷新包/哈希）：保留原 updated_at，不广播
    getDb()
      .prepare(
        `UPDATE key_escrow SET package = ?, passphrase_hash = ? WHERE space_id = ?`
      )
      .run(JSON.stringify(pkg), passphraseHash ?? null, "")
  }
  return { ok: true }
}

/**
 * POST /recover：全丢恢复（免认证——新设备尚未登记，凭"escrow 口令"作为管理员凭据）。
 * 口令用上传时存的 argon2id 哈希验证；通过后撤销全部 active 设备（空间重置），
 * 新设备可再次首设备自举。安全边界：口令即空间级管理员密钥，须妥善保管。
 */
export async function recoverSpace (
  cfg: ServerConfig,
  body: unknown
): Promise<{ ok: true; revoked: number; package?: unknown }> {
  const passphrase = (body as { passphrase?: unknown })?.passphrase
  if (typeof passphrase !== 'string' || passphrase.length === 0) {
    throw new ApiError('INVALID_REQUEST', 'passphrase 必填', 400)
  }
  const db = getDb()
  const row = db
    .prepare(
      `SELECT passphrase_hash, package FROM key_escrow WHERE space_id = ?`
    )
    .get("") as
    | { passphrase_hash: string | null; package: string | null }
    | undefined
  if (!row || !row.passphrase_hash) {
    throw new ApiError('FORBIDDEN', '未上传口令密保箱，无法恢复', 403)
  }
  if (!(await pwhashStrVerify(row.passphrase_hash, passphrase))) {
    throw new ApiError('FORBIDDEN', '口令错误', 403)
  }

  // 撤销全部 active 设备 + 清会话/推送令牌/邀请码 → 空间回到"空"状态，新设备可首设备自举
  const actives = db
    .prepare(`SELECT device_id FROM devices WHERE status = 'active'`)
    .all() as { device_id: string }[]
  const revoked = db
    .prepare(
      `UPDATE devices SET status = 'revoked', last_seen = ? WHERE status = 'active'`
    )
    .run(Date.now()).changes
  db.prepare(`DELETE FROM sessions`).run()
  db.prepare(`DELETE FROM push_tokens`).run()
  db.prepare(`DELETE FROM invites`).run()
  // 在线旧设备立即收到 device.revoked（发帧后服务端关连接）→ 客户端提示退出；
  // 恢复方是尚未登记的新设备（无 WS 连接），不受影响。
  for (const { device_id } of actives) notifyRevoked(device_id)

  // 闭环：口令正确即空间主人——顺带返回 escrow 密文包，新设备凭同一口令解出
  // Space Key（不再依赖预先导出的 EINZ-BACKUP 文本）。包本身口令加密，与
  // GET /key-escrow 同构；未托管口令密保箱（理论边界）时省略该字段。
  const pkg = row.package ? (JSON.parse(row.package) as unknown) : undefined
  return { ok: true, revoked, ...(pkg !== undefined ? { package: pkg } : {}) }
}

/** GET /key-escrow：拉取密文包（无包时返回空对象）。 */
export function getKeyEscrow (
  cfg: ServerConfig,
  token: string
): { package?: EscrowPackage; updated_at?: number } {
  const { device_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const row = getDb()
    .prepare(`SELECT package, updated_at FROM key_escrow WHERE space_id = ?`)
    .get("") as { package: string; updated_at: number } | undefined
  return row
    ? {
        package: JSON.parse(row.package) as EscrowPackage,
        updated_at: row.updated_at
      }
    : {}
}

/** DELETE /key-escrow：清除密文包。 */
export function deleteKeyEscrow (
  cfg: ServerConfig,
  token: string
): { ok: true } {
  const { device_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  getDb().prepare(`DELETE FROM key_escrow WHERE space_id = ?`).run("")
  return { ok: true }
}

/**
 * Multiverse：按空间读写口令托管包（POST /spaces/{spaceId}/key-escrow，
 * PROTOCOL_MULTIVERSE.md §4.2）：
 * - 上传/更新：{ package, passphrase_hash? }（沿用 v1 upload 语义，按 spaceId 隔离）；
 * - 取包：{ passphrase } → argon2id 校验口令，正确才返回密封包（区别于 /recover
 *   的"全丢重置"语义——加入方取钥不撤销任何设备）。
 * 骨架阶段无 session 认证，成员权限由 U1 Space-scoped session 补齐。
 */
export async function escrowForSpace (
  spaceId: string,
  body: unknown
): Promise<{ ok: true } | { ok: true; package: EscrowPackage }> {
  const sp = getDb()
    .prepare(`SELECT 1 FROM spaces WHERE space_id = ?`)
    .get(spaceId)
  if (!sp) throw new ApiError('SPACE_NOT_FOUND', 'space not found', 404)

  const b = (body ?? {}) as Record<string, unknown>
  if (b.passphrase != null) {
    // 取包：验证口令（口令即"拿到 Space Key 的凭证"，与 v1 recover 同边界）
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
      throw new ApiError('ESCROW_VERIFY_FAILED', '口令错误', 401)
    }
    return { ok: true, package: JSON.parse(row.package) as EscrowPackage }
  }

  // 上传/更新（UPSERT，最新者胜——与 v1 upload 一致）
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
