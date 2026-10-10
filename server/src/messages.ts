import { getDb } from "./db.js";
import { ApiError, touchLastSeen } from "./auth.js";
import { requireSession } from "./guard.js";
import { type ServerConfig } from "./config.js";
import { attachmentsForMessages, deleteAttachmentFiles, type AttachmentMeta } from "./attachments.js";
import { assertSafeMessageId } from "./safeId.js";

const ALLOWED_TYPES = new Set(["text", "image", "video", "voice", "audio", "file", "system"]);

export interface MessageEnvelope {
  v: number;
  type: string;
  key_version: number;
  message_id: string;
  sender_entrance_id: string;
  sender_member_id?: string;
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
    typeof b.sender_entrance_id !== "string" ||
    typeof b.nonce !== "string" ||
    typeof b.ciphertext !== "string" || b.ciphertext.length === 0
  ) {
    throw new ApiError("INVALID_REQUEST", "invalid message envelope", 400);
  }
  // P1 路径遍历防御：message_id 会被客户端当作文件路径片段（App 媒体解密缓存
  // 按 message_id 拼缓存文件名）——此前只查了"非空字符串"（老板 2026-09-14）
  assertSafeMessageId(b.message_id);
  const sp = b.sender_member_id;
  if (sp !== undefined && typeof sp !== "string") {
    throw new ApiError("INVALID_REQUEST", "invalid sender_member_id", 400);
  }
  return {
    v: b.v,
    type: b.type,
    key_version: b.key_version,
    message_id: b.message_id,
    sender_entrance_id: b.sender_entrance_id,
    ...(sp !== undefined ? { sender_member_id: sp as string } : {}),
    nonce: b.nonce,
    ciphertext: b.ciphertext,
  };
}

/** POST /messages：持久化密文并分配 server_sequence；同一 message_id 幂等（PROTOCOL.md §5.1）。
 *  Multiverse：写入 session 绑定的 Space（legacy 回落 cfg.space_id），幂等与
 *  server_sequence 均按 Space 隔离（PROTOCOL_MULTIVERSE.md §3.6）。 */
export function postMessage(token: string, body: unknown): { message_id: string; server_sequence: number; created_at: number } {
  const { entrance_id, space_id: sessionSpace } = requireSession(token);
  touchLastSeen(entrance_id);
  const spaceId = sessionSpace ?? ""; // v2：session 必带 Space（legacy 无空间 → 空串）

  const env = validateEnvelope(body);

  const db = getDb();
  // 幂等查询排在通道校验**之前**（老板 2026-09-22 定）：message_id 已是身份，
  // 已入库的消息写入是 no-op，没有可伪造的归因，因此不必也不该校验
  // sender_entrance_id。反过来说，信封里的 sender_entrance_id 是 AAD 的一部分
  // （shared/lib/src/crypto/message_crypto.dart），客户端换通道后**无法改写**——
  // 校验若排在前面，历史消息的重投会永远 403，本地状态再也回不来
  // （2026-09-22 实测：iMac 客户端两条 9/18 的消息永远停在"点击重发"红色标签）。
  // 查询按会话 Space 隔离（space_id = ?），因此不会跨空间探测或泄漏。
  const existing = db
    .prepare(`SELECT server_sequence, created_at FROM messages WHERE message_id = ? AND space_id = ?`)
    .get(env.message_id, spaceId) as { server_sequence: number; created_at: number } | undefined;
  if (existing) {
    return { message_id: env.message_id, server_sequence: existing.server_sequence, created_at: existing.created_at };
  }

  // 未入库的新消息：仍必须由本通道本人投递
  if (env.sender_entrance_id !== entrance_id) {
    throw new ApiError("FORBIDDEN", "sender_entrance_id mismatch", 403);
  }

  const now = Date.now();
  // Multiverse：server_sequence 按 Space 独立递增（不是全局）
  const nextSeq = db
    .prepare(`SELECT COALESCE(MAX(server_sequence), 0) + 1 AS next FROM messages WHERE space_id = ?`)
    .get(spaceId) as { next: number };

  db.prepare(
    `INSERT INTO messages (message_id, space_id, sender_entrance_id, sender_member_id, type, key_version, nonce, ciphertext, server_sequence, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(env.message_id, spaceId, env.sender_entrance_id, env.sender_member_id ?? null, env.type, env.key_version, env.nonce, env.ciphertext, nextSeq.next, now);

  return { message_id: env.message_id, server_sequence: nextSeq.next, created_at: now };
}

/** 撤回一条「服务端已收下、对方尚未拉取」的消息（老板 2026-10-10）。
 *
 * 可撤判定（单事务内原子完成，杜绝「校验通过到删除之间对方恰好 sync 走」竞态）：
 * 本 space 内**其他成员**的 delivered 高水位全部 < 本条 server_sequence。
 * 2 人空间即"对方没拉过"；将来群组该条件自动升级为"所有人都没拉过"。
 *
 * 动作：真删 messages 行 + attachments 行 + blob 文件（不走 10 分钟孤儿窗口）。
 * 行删了 /sync 永远不会把这条给对方；已落对方本地库的极端窗口（delivered 上报
 * 延迟）见 docs 附件撤回设计备注——E2EE 密文，风险可接受。
 *
 * 错误码：404 消息不存在/不属于本 space；403 非本人发送；409 已送达不可撤。
 */
export function recallMessage (
  token: string,
  messageId: string
): { message_id: string; server_sequence: number } {
  const { entrance_id, space_id: spaceId, member_id: myMemberId } = requireSession(token)
  touchLastSeen(entrance_id)
  assertSafeMessageId(messageId)

  const db = getDb()
  const result = db.transaction(() => {
    const row = db
      .prepare(`SELECT message_id, sender_entrance_id, sender_member_id, server_sequence FROM messages WHERE message_id = ? AND space_id = ?`)
      .get(messageId, spaceId) as { message_id: string; sender_entrance_id: string; sender_member_id: string | null; server_sequence: number } | undefined
    if (!row) throw new ApiError('NOT_FOUND', 'message not found', 404)
    // 归因校验：只有发送者本人能撤。sender_member_id 为 NULL 的 legacy 消息
    // 按 sender_entrance_id 对照当前通道（同 member 的历史通道也放行）。
    const mine = row.sender_member_id != null
      ? row.sender_member_id === myMemberId
      : row.sender_entrance_id === entrance_id
    if (!mine) throw new ApiError('FORBIDDEN', 'not the sender', 403)

    // 对方（本 space 其他成员）delivered 高水位全部 < 本条 seq 才可撤
    const others = db
      .prepare(`SELECT COALESCE(MAX(delivered_upto_seq), 0) AS max_delivered FROM receipts WHERE space_id = ? AND member_id != ?`)
      .get(spaceId, myMemberId) as { max_delivered: number }
    if (others.max_delivered >= row.server_sequence) {
      throw new ApiError('ALREADY_DELIVERED', 'peer already fetched this message', 409)
    }

    // 附件：先取 storage_path（事务内删行，文件删放在事务外——文件系统操作
    // 不参与 SQLite 事务，失败也只是孤儿文件，孤儿清理兜底）
    const atts = db
      .prepare(`SELECT storage_path FROM attachments WHERE message_id = ? AND space_id = ?`)
      .all(messageId, spaceId) as { storage_path: string }[]
    db.prepare(`DELETE FROM attachments WHERE message_id = ? AND space_id = ?`).run(messageId, spaceId)
    db.prepare(`DELETE FROM messages WHERE message_id = ? AND space_id = ?`).run(messageId, spaceId)
    return { message_id: row.message_id, server_sequence: row.server_sequence, storagePaths: atts.map(a => a.storage_path) }
  })() as { message_id: string; server_sequence: number; storagePaths: string[] }
  // 事务提交后才删文件：文件系统操作不参与 SQLite 事务（见上注释）
  deleteAttachmentFiles(spaceId, result.storagePaths)
  return { message_id: result.message_id, server_sequence: result.server_sequence }
}

/** GET /sync?after=&limit=：按 server_sequence 增量拉取（PROTOCOL.md §5.2）。 */
export function syncMessages(
  token: string,
  after: number,
  limit: number
): { messages: StoredMessage[]; attachments_meta: AttachmentMeta[]; last_sequence: number; has_more: boolean } {
  const { entrance_id, space_id: sessionSpace } = requireSession(token);
  touchLastSeen(entrance_id);
  const spaceId = sessionSpace ?? ""; // v2：session 必带 Space（legacy 无空间 → 空串）

  const safeLimit = Math.min(Math.max(limit, 1), 500);
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT message_id, sender_entrance_id, sender_member_id, type, key_version, nonce, ciphertext, server_sequence, created_at
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
