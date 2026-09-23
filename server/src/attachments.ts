import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join, resolve, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { getDb } from "./db.js";
import { ApiError, touchLastSeen } from "./auth.js";
import { requireSession } from "./guard.js";
import { type ServerConfig } from "./config.js";
import { assertSafeSpaceId } from "./safeId.js";

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

/** 附件按**空间分片**落盘：`data/files/<space_id>/<前2位>/<attachment_id>`
 *  （老板 2026-09-23：per-space 备份/销毁/用量统计都依赖它；鉴权早就按 space 隔离了，
 *  这里补的是文件层）。space_id 由客户端自报 → 入口已收字符集（safeId.assertSafeSpaceId），
 *  此处再校验一次（纵深防御，拼路径前必过）。 */
export function spaceFileDir(spaceId: string): string {
  assertSafeSpaceId(spaceId);
  return join(FILES_ROOT, spaceId);
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

/** 校验附件元数据与 blob（sha256 = 密文哈希），落盘并入库（PROTOCOL.md §6.1）。
 *  同一 attachment_id 重复上传**幂等返回原记录**（网络重试安全，见下方注释）。 */
export function storeAttachment(
  token: string,
  meta: { message_id: string; attachment_id: string; key_version: number; size: number; sha256: string; nonce: string },
  blob: Buffer
): { attachment_id: string; storage_path: string; created_at: number } {
  const { device_id, space_id: spaceId } = requireSession(token);
  touchLastSeen(device_id);

  // P1 路径遍历防御：attachment_id/message_id 必须在安全字符集内（拒绝 / . \ 等）
  assertSafeId(meta.attachment_id, "attachment_id");
  assertSafeId(meta.message_id, "message_id");

  const db = getDb();

  // C2 空间归属校验：attachment_id 与 message_id 都是**客户端生成**的，不校验
  // 就能把 blob 挂到别的空间的消息上（对方的 /sync 会收到我方附件元数据），
  // 或顶掉别的空间的同名 attachment_id。两处都必须与本会话空间一致。
  const stored = db
    .prepare(`SELECT space_id, storage_path, created_at FROM attachments WHERE attachment_id = ?`)
    .get(meta.attachment_id) as
    | { space_id: string; storage_path: string; created_at: number }
    | undefined;
  if (stored && stored.space_id !== spaceId) {
    throw new ApiError("FORBIDDEN", "attachment_id belongs to another space", 403);
  }
  const host = db
    .prepare(`SELECT space_id FROM messages WHERE message_id = ?`)
    .get(meta.message_id) as { space_id: string } | undefined;
  if (host && host.space_id !== spaceId) {
    throw new ApiError("FORBIDDEN", "message_id belongs to another space", 403);
  }

  if (blob.length !== meta.size) throw new ApiError("INVALID_REQUEST", "size mismatch", 400);
  const sha = createHash("sha256").update(blob).digest("base64");
  if (sha !== meta.sha256) throw new ApiError("INVALID_REQUEST", "sha256 mismatch", 400);

  // 幂等（2026-09-15 评审 C2）：同一 attachment_id 重复上传 → 返回原记录，而不是
  // 500。两阶段上传（PROTOCOL.md §6.1）遇到网络抖动时客户端会用**同一个
  // attachment_id** 重传，此前写盘的 `flag: "wx"` 会撞 EEXIST 直接抛成 500
  // （实测：隔离测试第二次跑就复现）。语义与 /messages 的 message_id 幂等一致。
  if (stored) {
    return { attachment_id: meta.attachment_id, storage_path: stored.storage_path, created_at: stored.created_at };
  }

  // 按空间分片 + attachment_id 前两位二级分片（per-space：`data/files/<space_id>/..`）
  const shard = meta.attachment_id.slice(0, 2);
  const dir = join(spaceFileDir(spaceId), shard);
  mkdirSync(dir, { recursive: true });
  const storagePath = `${spaceId}/${shard}/${meta.attachment_id}`;
  const full = join(FILES_ROOT, storagePath);
  assertInsideFilesRoot(full);
  // 记录不存在但文件在（上次写盘后、入库前崩了）：内容一致就复用，不一致说明
  // 这个 id 被复用于不同内容 → 409（不能静默覆盖别人的 blob）
  if (existsSync(full)) {
    const existing = readFileSync(full);
    if (createHash("sha256").update(existing).digest("base64") !== meta.sha256) {
      throw new ApiError("CONFLICT", "attachment_id already stored with different content", 409);
    }
  } else {
    writeFileSync(full, blob, { flag: "wx" });
  }

  const now = Date.now();
  // v2 多空间：附件归属取会话绑定的 Space（spaceId 已在上面解析，同 postMessage）。
  // 注意：两阶段上传（PROTOCOL.md §6.1）先传 blob 后发消息——此刻 messages
  // 行尚不存在，不能从消息反查 space_id（否则 NULL 落入 NOT NULL 列 → 500，
  // 上传失败 → 发送端气泡回退「📎 文件名」、接收端 /sync 无附件元数据）。
  db.prepare(
    `INSERT INTO attachments (attachment_id, message_id, space_id, key_version, size, sha256, nonce, storage_path, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(meta.attachment_id, meta.message_id, spaceId, meta.key_version, meta.size, meta.sha256, meta.nonce, storagePath, now);

  return { attachment_id: meta.attachment_id, storage_path: storagePath, created_at: now };
}

/** 下载附件 blob（PROTOCOL.md §6.2）：鉴权 + 白名单校验 + **空间归属**校验。 */
export function getAttachmentBlob(token: string, attachmentId: string): Buffer {
  const { device_id, space_id: spaceId } = requireSession(token);
  touchLastSeen(device_id);

  assertSafeId(attachmentId, "attachment_id");

  const row = getDb()
    .prepare(`SELECT storage_path, space_id FROM attachments WHERE attachment_id = ?`)
    .get(attachmentId) as { storage_path: string; space_id: string } | undefined;
  // 404 而非 403：不向非成员确认"这个 attachment_id 存在"（元数据最小化，C2）
  if (!row) throw new ApiError("NOT_FOUND", "attachment not found", 404);
  if (row.space_id !== spaceId) {
    throw new ApiError("NOT_FOUND", "attachment not found", 404);
  }

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
