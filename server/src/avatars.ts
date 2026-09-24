import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { getDb } from "./db.js";
import { requireSession } from "./guard.js";
import { ApiError } from "./auth.js";
import { type ServerConfig } from "./config.js";

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));
const AVATARS_ROOT = process.env.EINZ_AVATARS ?? resolve(HERE, "../data/avatars");

/** 宽松 memberId 校验（P1 路径遍历防御）：UUID / 规范 id 等字母数字 + 下划线/连字符，
 *  杜绝 /、.、\ 等路径字符。 */
const SAFE_MEMBER_RE = /^[A-Za-z0-9_-]{1,64}$/;
function assertSafeMemberId(memberId: string): void {
  if (typeof memberId !== "string" || !SAFE_MEMBER_RE.test(memberId)) {
    throw new ApiError("INVALID_REQUEST", "invalid member id: illegal characters", 400);
  }
}

/** 头像大小上限（2MB，png/jpg 均足够）。上传路由用它做请求体上限，避免先
 *  把超大 body 读进内存再判超限（2026-09-15 评审 H1）。 */
export const MAX_AVATAR_BYTES = 2 * 1024 * 1024;

/** 上传本人头像：token 认证 → 解析通道 → 查 member_id → 写文件（覆盖旧头像）。 */
export function storeAvatar(
  token: string,
  blob: Buffer
): { member_id: string; size: number } {
  const { entrance_id } = requireSession(token);
  const row = getDb()
    .prepare(`SELECT member_id FROM entrances WHERE entrance_id = ?`)
    .get(entrance_id) as { member_id: string } | undefined;
  if (!row) throw new ApiError("FORBIDDEN", "entrance not found", 403);
  const memberId = row.member_id;
  assertSafeMemberId(memberId);
  if (blob.length === 0) throw new ApiError("INVALID_REQUEST", "empty avatar body", 400);
  if (blob.length > MAX_AVATAR_BYTES) throw new ApiError("INVALID_REQUEST", "avatar too large (max 2MB)", 413);
  mkdirSync(AVATARS_ROOT, { recursive: true });
  writeFileSync(join(AVATARS_ROOT, memberId), blob);
  return { member_id: memberId, size: blob.length };
}

/** 获取头像：不存在返回 null（路由发 404）。 */
export function getAvatar(memberId: string): Buffer | null {
  assertSafeMemberId(memberId);
  const full = join(AVATARS_ROOT, memberId);
  if (!existsSync(full)) return null;
  return readFileSync(full);
}
