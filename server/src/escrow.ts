import { getDb } from "./db.js";
import { ApiError, resolveSession } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";

/**
 * 口令托管密钥（KEY_ESCROW.md §4）：Server 只托管"被口令加密的 Space Key 包"，
 * 不解析内容——没有口令（Argon2id 派生）任何人都无法解开。
 * 按 space 存一份（双方同一口令），更新以最新者胜。
 */

export interface EscrowPackage {
  format: string;
  salt: string;
  nonce: string;
  ciphertext: string;
}

/** 校验包结构（仅字段类型，不解析内容）。 */
function parsePackage(raw: unknown): EscrowPackage {
  if (typeof raw !== "object" || raw === null) throw new ApiError("INVALID_REQUEST", "invalid key-escrow package", 400);
  const p = raw as Record<string, unknown>;
  for (const k of ["format", "salt", "nonce", "ciphertext"] as const) {
    if (typeof p[k] !== "string" || (p[k] as string).length === 0) {
      throw new ApiError("INVALID_REQUEST", `invalid key-escrow field: ${k}`, 400);
    }
  }
  return p as unknown as EscrowPackage;
}

/** POST /key-escrow：上传/更新密文包（UPSERT，按 space 一份）。 */
export function uploadKeyEscrow(cfg: ServerConfig, token: string, body: unknown): { ok: true } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);

  const pkg = parsePackage((body as { package?: unknown })?.package);
  getDb()
    .prepare(
      `INSERT INTO key_escrow (space_id, package, updated_at)
       VALUES (?, ?, ?)
       ON CONFLICT(space_id) DO UPDATE SET package = excluded.package, updated_at = excluded.updated_at`
    )
    .run(cfg.space_id, JSON.stringify(pkg), Date.now());
  return { ok: true };
}

/** GET /key-escrow：拉取密文包（无包时返回空对象）。 */
export function getKeyEscrow(cfg: ServerConfig, token: string): { package?: EscrowPackage } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);

  const row = getDb().prepare(`SELECT package FROM key_escrow WHERE space_id = ?`).get(cfg.space_id) as
    | { package: string }
    | undefined;
  return row ? { package: JSON.parse(row.package) as EscrowPackage } : {};
}

/** DELETE /key-escrow：清除密文包。 */
export function deleteKeyEscrow(cfg: ServerConfig, token: string): { ok: true } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);

  getDb().prepare(`DELETE FROM key_escrow WHERE space_id = ?`).run(cfg.space_id);
  return { ok: true };
}
