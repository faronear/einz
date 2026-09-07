import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { getDb } from "./db.js";
import { ApiError, resolveSession } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));
const AVATARS_ROOT = process.env.EINZ_AVATARS ?? resolve(HERE, "../data/avatars");

/** 宽松 personId 校验（P1 路径遍历防御）：personA/personB 等字母数字 + 下划线/连字符，
 *  杜绝 /、.、\ 等路径字符。 */
const SAFE_PERSON_RE = /^[A-Za-z0-9_-]{1,64}$/;
function assertSafePersonId(personId: string): void {
  if (typeof personId !== "string" || !SAFE_PERSON_RE.test(personId)) {
    throw new ApiError("INVALID_REQUEST", "invalid person id: illegal characters", 400);
  }
}

/** 头像大小上限（2MB，png/jpg 均足够）。 */
const MAX_AVATAR_BYTES = 2 * 1024 * 1024;

/** 上传本人头像：token 认证 → 解析设备 → 查 person_id → 写文件（覆盖旧头像）。 */
export function storeAvatar(
  cfg: ServerConfig,
  token: string,
  blob: Buffer
): { person_id: string; size: number } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  const row = getDb()
    .prepare(`SELECT person_id FROM devices WHERE device_id = ?`)
    .get(device_id) as { person_id: string } | undefined;
  if (!row) throw new ApiError("FORBIDDEN", "device not found", 403);
  const personId = row.person_id;
  assertSafePersonId(personId);
  if (blob.length === 0) throw new ApiError("INVALID_REQUEST", "empty avatar body", 400);
  if (blob.length > MAX_AVATAR_BYTES) throw new ApiError("INVALID_REQUEST", "avatar too large (max 2MB)", 413);
  mkdirSync(AVATARS_ROOT, { recursive: true });
  writeFileSync(join(AVATARS_ROOT, personId), blob);
  return { person_id: personId, size: blob.length };
}

/** 获取头像：不存在返回 null（路由发 404）。 */
export function getAvatar(personId: string): Buffer | null {
  assertSafePersonId(personId);
  const full = join(AVATARS_ROOT, personId);
  if (!existsSync(full)) return null;
  return readFileSync(full);
}
