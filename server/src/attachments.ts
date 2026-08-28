import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { getDb } from "./db.js";
import { ApiError, resolveSession, touchLastSeen } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";

const FILES_ROOT = process.env.ONLYSPACE_FILES ?? resolve(import.meta.dirname, "../data/files");

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

  const db = getDb();
  const msg = db.prepare(`SELECT message_id FROM messages WHERE message_id = ?`).get(meta.message_id);
  if (!msg) throw new ApiError("INVALID_REQUEST", "message not found", 400);

  if (blob.length !== meta.size) throw new ApiError("INVALID_REQUEST", "size mismatch", 400);
  const sha = createHash("sha256").update(blob).digest("base64");
  if (sha !== meta.sha256) throw new ApiError("INVALID_REQUEST", "sha256 mismatch", 400);

  // 按 attachment_id 前两位分片目录
  const shard = meta.attachment_id.slice(0, 2);
  const dir = join(FILES_ROOT, shard);
  mkdirSync(dir, { recursive: true });
  const storagePath = `${shard}/${meta.attachment_id}`;
  writeFileSync(join(FILES_ROOT, storagePath), blob, { flag: "wx" });

  const now = Date.now();
  db.prepare(
    `INSERT INTO attachments (attachment_id, message_id, space_id, key_version, size, sha256, nonce, storage_path, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(meta.attachment_id, meta.message_id, cfg.space_id, meta.key_version, meta.size, meta.sha256, meta.nonce, storagePath, now);

  return { attachment_id: meta.attachment_id, storage_path: storagePath, created_at: now };
}

/** 下载附件 blob（PROTOCOL.md §6.2）：鉴权 + 白名单校验。 */
export function getAttachmentBlob(cfg: ServerConfig, token: string, attachmentId: string): Buffer {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);

  const row = getDb()
    .prepare(`SELECT storage_path FROM attachments WHERE attachment_id = ?`)
    .get(attachmentId) as { storage_path: string } | undefined;
  if (!row) throw new ApiError("NOT_FOUND", "attachment not found", 404);

  const full = join(FILES_ROOT, row.storage_path);
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
