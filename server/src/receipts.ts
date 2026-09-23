import { getDb } from './db.js'
import { ApiError } from './auth.js'
import { requireSession } from './guard.js'
import { broadcastReceiptUpdated } from './ws.js'

/**
 * 消息回执（已送达/已读）：单调高水位（HWM），按 (space_id, partner_id) 一行。
 *
 * 为什么不按消息逐条记：messages.server_sequence 已保证 space 内单调，"对方已
 * 收到/已读到第 N 条"就足以推导任意一条消息的状态，且天然 O(1) 存储、幂等、
 * 可批量——无需逐条 ACK。
 *
 * 语义与不变式：
 * - 我的消息 seq=S 已送达 ⟺ 对方 delivered_upto_seq ≥ S；已读 ⟺ read_upto_seq ≥ S。
 * - 只前进（max 夹紧），且 delivered_upto_seq ≥ read_upto_seq（读隐含送达）。
 * - 按 partner 记 → "该 partner 至少一条通道已收到/已读"，不保证其所有通道。
 *   2 人空间足够；将来要"所有通道"需改为按通道记。
 */

export interface ReceiptRow {
  partner_id: string
  delivered_upto_seq: number
  read_upto_seq: number
  updated_at: number
}

/** 取当前 entrance 的 partner_id（entrances 表是全局表，partner 是身份锚点）。 */
function partnerOfEntrance (entranceId: string): string {
  const row = getDb()
    .prepare(`SELECT partner_id FROM entrances WHERE entrance_id = ?`)
    .get(entranceId) as { partner_id: string } | undefined
  if (!row) throw new ApiError('FORBIDDEN', 'entrance not found', 403)
  return row.partner_id
}

/** 本 space 当前最大 server_sequence：上报值的上限（防有 bug 的客户端报未来 seq）。 */
function maxSequence (spaceId: string): number {
  const row = getDb()
    .prepare(
      `SELECT COALESCE(MAX(server_sequence), 0) AS max_seq FROM messages WHERE space_id = ?`
    )
    .get(spaceId) as { max_seq: number }
  return row.max_seq
}

/** 非负整数校验（缺省视为 0）。 */
function asSeq (raw: unknown, field: string): number {
  if (raw === undefined || raw === null) return 0
  if (typeof raw !== 'number' || !Number.isInteger(raw) || raw < 0) {
    throw new ApiError('INVALID_REQUEST', `${field} 必须是非负整数`, 400)
  }
  return raw
}

/**
 * POST /receipts：上报自己的送达/已读 HWM。
 * body { delivered_upto_seq?, read_upto_seq? }（均非负整数，可只传其一）
 * 返回调用方夹紧后的 { delivered_upto_seq, read_upto_seq }。
 */
export function postReceipts (
  token: string,
  body: unknown
): { delivered_upto_seq: number; read_upto_seq: number } {
  const { entrance_id, space_id } = requireSession(token)

  const b = (body ?? {}) as Record<string, unknown>
  const cap = maxSequence(space_id)
  const clamp = (n: number): number => Math.min(n, cap)
  const delivered = clamp(asSeq(b.delivered_upto_seq, 'delivered_upto_seq'))
  const read = clamp(asSeq(b.read_upto_seq, 'read_upto_seq'))
  const partnerId = partnerOfEntrance(entrance_id)

  // 单条 SQL 原子 upsert：只前进，且 delivered ≥ read（读隐含送达）。
  // 禁止先读后写——并发上报下会互相覆盖。
  getDb()
    .prepare(
      `INSERT INTO receipts (space_id, partner_id, delivered_upto_seq, read_upto_seq, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(space_id, partner_id) DO UPDATE SET
         delivered_upto_seq = MAX(receipts.delivered_upto_seq,
                                  MAX(excluded.delivered_upto_seq, excluded.read_upto_seq)),
         read_upto_seq      = MAX(receipts.read_upto_seq, excluded.read_upto_seq),
         updated_at         = excluded.updated_at`
    )
    .run(space_id, partnerId, delivered, read, Date.now())

  const row = getDb()
    .prepare(
      `SELECT partner_id, delivered_upto_seq, read_upto_seq, updated_at
       FROM receipts WHERE space_id = ? AND partner_id = ?`
    )
    .get(space_id, partnerId) as ReceiptRow

  // 通知同空间的其他通道（含自己 partner 的其他通道与对方）
  broadcastReceiptUpdated(entrance_id, {
    partner_id: row.partner_id,
    delivered_upto_seq: row.delivered_upto_seq,
    read_upto_seq: row.read_upto_seq
  })

  return {
    delivered_upto_seq: row.delivered_upto_seq,
    read_upto_seq: row.read_upto_seq
  }
}

/** GET /receipts：本 space 全部回执行（重连/补拉用）。 */
export function getReceipts (
  token: string
): { receipts: ReceiptRow[] } {
  const { entrance_id, space_id } = requireSession(token)

  const rows = getDb()
    .prepare(
      `SELECT partner_id, delivered_upto_seq, read_upto_seq, updated_at
       FROM receipts WHERE space_id = ? ORDER BY updated_at ASC`
    )
    .all(space_id) as ReceiptRow[]
  return { receipts: rows }
}

/**
 * GET /messages/unread：本空间里"对方发来的、晚于我读取水位"的消息条数。
 *
 * 用途：多空间列表的未读角标（老板 2026-09-22 定：**服务端派生**——不在客户端拉
 * 各空间的历史、也不加本地 schema；离线时列表不显示未读数，可接受）。
 *
 * 数据全是现成的：读取水位 = [receipts.read_upto_seq]（客户端在"用户真看到最新消息"
 * 时才上报，见 chat_page._scheduleReadReport），消息与发送者分别在 messages / entrances。
 *
 * 判定"不是我发的"**必须走 partner 维度**：同一身份可能有多台登记项，只比 entrance_id
 * 会把自己的另一条通道发来的消息算成未读。
 *
 * 刻意**不要求** receipts 行存在：没有行 = 从没读过 = 对方的全部消息都算未读。
 */
export function unreadCount (token: string): { unread: number } {
  const { entrance_id, space_id } = requireSession(token)
  const partnerId = partnerOfEntrance(entrance_id)

  const { read_seq: readSeq } = getDb()
    .prepare(
      `SELECT COALESCE(MAX(read_upto_seq), 0) AS read_seq
       FROM receipts WHERE space_id = ? AND partner_id = ?`
    )
    .get(space_id, partnerId) as { read_seq: number }

  const { n } = getDb()
    .prepare(
      `SELECT COUNT(*) AS n
         FROM messages m
         LEFT JOIN entrances d ON d.entrance_id = m.sender_entrance_id
        WHERE m.space_id = ?
          AND m.server_sequence > ?
          AND (d.partner_id IS NULL OR d.partner_id != ?)`
    )
    .get(space_id, readSeq, partnerId) as { n: number }

  return { unread: n }
}
