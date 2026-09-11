import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join, resolve, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { getDb } from "./db.js";
import { ApiError, resolveSession, touchLastSeen } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));
const FILES_ROOT = process.env.EINZ_FILES ?? resolve(HERE, "../data/files");

/** 宽松 ID 校验（P1 路径遍历防御）：仅允许 hex + 连字符，杜绝 /、.、\ 等路径字符。
 *  CLI 生成的附件/消息 ID 为 38 字符非标准 UUID，故不强制 UUID 格式，只做字符集白名单。 */
const SAFE_ID_RE = /^[0-9a-fA-F-]{8,64}$/;
function assertSafeId(id: string, what: string): void {
  if (typeof id !== "string" || !SAFE_ID_RE.test(id)) {
    throw new ApiError("INVALID_REQUEST", `invalid ${what}: illegal characters`, 400);
  }
}

/** 确保解析后的路径仍位于 FILES_ROOT 内（纵深防御，读写双侧生效）。 */
function assertInsideFilesRoot(full: string): void {
  // 用平台分隔符拼接 root，避免 Windows（resolve 返回 \）与 "/" 混用误判
  const root = resolve(FILES_ROOT) + sep;
  if (!resolve(full).startsWith(root)) {
    throw new ApiError("INVALID_REQUEST", "storage path escapes files root", 400);
  }
}

export interface AttachmentMeta {
  attachment_id: string;
  message_id: string;
  key_version: number;
  size: number;
  sha256: string;
  nonce: string;
  storage_path: string;
  created_at: number;
}

/** 校验附件元数据与 blob（sha256 = 密文哈希），落盘并入库（PROTOCOL.md §6.1）。 */
export function storeAttachment(
  cfg: ServerConfig,
  token: string,
  meta: { message_id: string; attachment_id: string; key_version: number; size: number; sha256: string; nonce: string },
  blob: Buffer
): { attachment_id: string; storage_path: string; created_at: number } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);

  // P1 路径遍历防御：attachment_id/message_id 必须在安全字符集内（拒绝 / . \ 等）
  assertSafeId(meta.attachment_id, "attachment_id");
  assertSafeId(meta.message_id, "message_id");

  const db = getDb();

  if (blob.length !== meta.size) throw new ApiError("INVALID_REQUEST", "size mismatch", 400);
  const sha = createHash("sha256").update(blob).digest("base64");
  if (sha !== meta.sha256) throw new ApiError("INVALID_REQUEST", "sha256 mismatch", 400);

  // 按 attachment_id 前两位分片目录
  const shard = meta.attachment_id.slice(0, 2);
  const dir = join(FILES_ROOT, shard);
  mkdirSync(dir, { recursive: true });
  const storagePath = `${shard}/${meta.attachment_id}`;
  const full = join(FILES_ROOT, storagePath);
  assertInsideFilesRoot(full);
  writeFileSync(full, blob, { flag: "wx" });

  const now = Date.now();
  // v2 多空间：附件归属消息所在空间（不再用全局 cfg.space_id——服务端已无全局 space）
  const msg = db
    .prepare(`SELECT space_id FROM messages WHERE message_id = ?`)
    .get(meta.message_id) as { space_id: string | null } | undefined;
  const spaceId = msg?.space_id ?? null;
  db.prepare(
    `INSERT INTO attachments (attachment_id, message_id, space_id, key_version, size, sha256, nonce, storage_path, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(meta.attachment_id, meta.message_id, spaceId, meta.key_version, meta.size, meta.sha256, meta.nonce, storagePath, now);

  return { attachment_id: meta.attachment_id, storage_path: storagePath, created_at: now };
}

/** 下载附件 blob（PROTOCOL.md §6.2）：鉴权 + 白名单校验。 */
export function getAttachmentBlob(cfg: ServerConfig, token: string, attachmentId: string): Buffer {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);

  assertSafeId(attachmentId, "attachment_id");

  const row = getDb()
    .prepare(`SELECT storage_path FROM attachments WHERE attachment_id = ?`)
    .get(attachmentId) as { storage_path: string } | undefined;
  if (!row) throw new ApiError("NOT_FOUND", "attachment not found", 404);

  const full = join(FILES_ROOT, row.storage_path);
  assertInsideFilesRoot(full);
  if (!existsSync(full)) throw new ApiError("NOT_FOUND", "attachment file missing", 404);
  return readFileSync(full);
}

/** 按消息列表取附件元数据（供 /sync 附加）。 */
export function attachmentsForMessages(messageIds: string[]): AttachmentMeta[] {
  if (messageIds.length === 0) return [];
  const db = getDb();
  const placeholders = messageIds.map(() => "?").join(",");
  return db
    .prepare(
      `SELECT attachment_id, message_id, key_version, size, sha256, nonce, storage_path, created_at
       FROM attachments WHERE message_id IN (${placeholders})`
    )
    .all(...messageIds) as AttachmentMeta[];
}

/** 孤儿附件窗口：两阶段上传（先 blob 后 message，PROTOCOL.md §6.1）正常间隔毫秒级，
 *  超过该窗口仍无对应 message 的 blob 视为孤儿（blob 已传但消息未发出/发送失败）。 */
const ORPHAN_WINDOW_MS = 10 * 60 * 1000;

/** 清理孤儿附件（无对应 message 且超过窗口期的 blob：删文件 + 删记录），返回清理数量。
 *  随 cleanupExpired 每小时定期调用。 */
export function cleanupOrphanAttachments(): number {
  const db = getDb();
  const cutoff = Date.now() - ORPHAN_WINDOW_MS;
  const orphans = db
    .prepare(
      `SELECT attachment_id, storage_path FROM attachments a
       WHERE a.created_at < ? AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.message_id = a.message_id)`
    )
    .all(cutoff) as { attachment_id: string; storage_path: string }[];
  for (const o of orphans) {
    const full = join(FILES_ROOT, o.storage_path);
    try {
      if (existsSync(full)) rmSync(full, { force: true });
    } catch {
      // 文件已缺失则跳过（记录仍删）
    }
    db.prepare(`DELETE FROM attachments WHERE attachment_id = ?`).run(o.attachment_id);
  }
  return orphans.length;
}
