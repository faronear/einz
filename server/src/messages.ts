import { getDb } from "./db.js";
import { ApiError, resolveSession, touchLastSeen } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";
import { attachmentsForMessages, type AttachmentMeta } from "./attachments.js";

const ALLOWED_TYPES = new Set(["text", "image", "video", "voice", "audio", "file", "system"]);

export interface MessageEnvelope {
  v: number;
  type: string;
  key_version: number;
  message_id: string;
  sender_device_id: string;
  sender_person_id?: string;
  nonce: string;
  ciphertext: string;
}

export interface StoredMessage extends MessageEnvelope {
  server_sequence: number;
  created_at: number;
}

function validateEnvelope(body: unknown): MessageEnvelope {
  const b = body as Record<string, unknown>;
  if (
    typeof b.v !== "number" || b.v !== 1 ||
    typeof b.type !== "string" || !ALLOWED_TYPES.has(b.type) ||
    typeof b.key_version !== "number" || b.key_version < 1 ||
    typeof b.message_id !== "string" || b.message_id.length === 0 ||
    typeof b.sender_device_id !== "string" ||
    typeof b.nonce !== "string" ||
    typeof b.ciphertext !== "string" || b.ciphertext.length === 0
  ) {
    throw new ApiError("INVALID_REQUEST", "invalid message envelope", 400);
  }
  const sp = b.sender_person_id;
  if (sp !== undefined && typeof sp !== "string") {
    throw new ApiError("INVALID_REQUEST", "invalid sender_person_id", 400);
  }
  return {
    v: b.v,
    type: b.type,
    key_version: b.key_version,
    message_id: b.message_id,
    sender_device_id: b.sender_device_id,
    ...(sp !== undefined ? { sender_person_id: sp as string } : {}),
    nonce: b.nonce,
    ciphertext: b.ciphertext,
  };
}

/** POST /messages：持久化密文并分配 server_sequence；同一 message_id 幂等（PROTOCOL.md §5.1）。
 *  Multiverse：写入 session 绑定的 Space（legacy 回落 cfg.space_id），幂等与
 *  server_sequence 均按 Space 隔离（PROTOCOL_MULTIVERSE.md §3.6）。 */
export function postMessage(cfg: ServerConfig, token: string, body: unknown): { message_id: string; server_sequence: number; created_at: number } {
  const { device_id, space_id: sessionSpace } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);
  const spaceId = sessionSpace ?? cfg.space_id; // legacy 回落

  const env = validateEnvelope(body);
  if (env.sender_device_id !== device_id) {
    throw new ApiError("FORBIDDEN", "sender_device_id mismatch", 403);
  }

  const db = getDb();
  const existing = db
    .prepare(`SELECT server_sequence, created_at FROM messages WHERE message_id = ? AND space_id = ?`)
    .get(env.message_id, spaceId) as { server_sequence: number; created_at: number } | undefined;
  if (existing) {
    return { message_id: env.message_id, server_sequence: existing.server_sequence, created_at: existing.created_at };
  }

  const now = Date.now();
  // Multiverse：server_sequence 按 Space 独立递增（不是全局）
  const nextSeq = db
    .prepare(`SELECT COALESCE(MAX(server_sequence), 0) + 1 AS next FROM messages WHERE space_id = ?`)
    .get(spaceId) as { next: number };

  db.prepare(
    `INSERT INTO messages (message_id, space_id, sender_device_id, sender_person_id, type, key_version, nonce, ciphertext, server_sequence, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(env.message_id, spaceId, env.sender_device_id, env.sender_person_id ?? null, env.type, env.key_version, env.nonce, env.ciphertext, nextSeq.next, now);

  return { message_id: env.message_id, server_sequence: nextSeq.next, created_at: now };
}

/** GET /sync?after=&limit=：按 server_sequence 增量拉取（PROTOCOL.md §5.2）。 */
export function syncMessages(
  cfg: ServerConfig,
  token: string,
  after: number,
  limit: number
): { messages: StoredMessage[]; attachments_meta: AttachmentMeta[]; last_sequence: number; has_more: boolean } {
  const { device_id, space_id: sessionSpace } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);
  const spaceId = sessionSpace ?? cfg.space_id; // legacy 回落

  const safeLimit = Math.min(Math.max(limit, 1), 500);
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT message_id, sender_device_id, sender_person_id, type, key_version, nonce, ciphertext, server_sequence, created_at
       FROM messages WHERE space_id = ? AND server_sequence > ?
       ORDER BY server_sequence ASC LIMIT ?`
    )
    .all(spaceId, after, safeLimit + 1) as StoredMessage[];

  // v 是协议常量（未入库），同步响应需补齐（PROTOCOL.md §5.2）
  const withVersion: StoredMessage[] = rows.map((r) => ({ ...r, v: 1 }));

  const hasMore = withVersion.length > safeLimit;
  const page = hasMore ? withVersion.slice(0, safeLimit) : withVersion;
  const last = page.length > 0 ? page[page.length - 1].server_sequence : after;

  // 附件元数据：随本页消息返回（PROTOCOL.md §5.2 attachments_meta）
  const messageIds = page.map((m) => m.message_id);
  const attachmentsMeta = attachmentsForMessages(messageIds);

  return { messages: page, attachments_meta: attachmentsMeta, last_sequence: last, has_more: hasMore };
}
