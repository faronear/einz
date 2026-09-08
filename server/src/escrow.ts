import { getDb } from './db.js'
import { ApiError, resolveSession } from './auth.js'
import { isActiveDevice, type ServerConfig } from './config.js'
import { pwhashStrVerify } from './crypto.js'
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
function parsePackage (raw: unknown): EscrowPackage {
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
  // 口令已重设（passphrase_hash 与旧值不同）→ 通知其余在线设备（客户端只发通知不弹窗）
  const prevRow = getDb()
    .prepare(`SELECT passphrase_hash FROM key_escrow WHERE space_id = ?`)
    .get(cfg.space_id) as { passphrase_hash: string | null } | undefined
  const hashVal = passphraseHash ?? null
  const rotated = prevRow !== undefined && prevRow.passphrase_hash !== hashVal
  getDb()
    .prepare(
      `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(space_id) DO UPDATE SET
         package = excluded.package,
         passphrase_hash = excluded.passphrase_hash,
         updated_at = excluded.updated_at`
    )
    .run(cfg.space_id, JSON.stringify(pkg), passphraseHash ?? null, Date.now())
  if (rotated) broadcastPassphraseRotated(device_id)
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
    .get(cfg.space_id) as
    | { passphrase_hash: string | null; package: string | null }
    | undefined
  if (!row || !row.passphrase_hash) {
    throw new ApiError('FORBIDDEN', '未上传口令密保箱，无法恢复', 403)
  }
  if (!(await pwhashStrVerify(row.passphrase_hash, passphrase))) {
    throw new ApiError('FORBIDDEN', '口令错误', 403)
  }

  // 撤销全部 active 设备 + 清会话/推送令牌/邀请码 → 空间回到"空"状态，新设备可首设备自举
  const revoked = db
    .prepare(
      `UPDATE devices SET status = 'revoked', last_seen = ? WHERE status = 'active'`
    )
    .run(Date.now()).changes
  db.prepare(`DELETE FROM sessions`).run()
  db.prepare(`DELETE FROM push_tokens`).run()
  db.prepare(`DELETE FROM invites`).run()

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
    .get(cfg.space_id) as { package: string; updated_at: number } | undefined
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

  getDb().prepare(`DELETE FROM key_escrow WHERE space_id = ?`).run(cfg.space_id)
  return { ok: true }
}
