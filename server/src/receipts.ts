import { getDb } from './db.js'
import { ApiError } from './auth.js'
import { requireSession } from './guard.js'
import { broadcastReceiptUpdated } from './ws.js'

/**
 * 消息回执（已送达/已读）：单调高水位（HWM），按 (space_id, person_id) 一行。
 *
 * 为什么不按消息逐条记：messages.server_sequence 已保证 space 内单调，"对方已
 * 收到/已读到第 N 条"就足以推导任意一条消息的状态，且天然 O(1) 存储、幂等、
 * 可批量——无需逐条 ACK。
 *
 * 语义与不变式：
 * - 我的消息 seq=S 已送达 ⟺ 对方 delivered_upto_seq ≥ S；已读 ⟺ read_upto_seq ≥ S。
 * - 只前进（max 夹紧），且 delivered_upto_seq ≥ read_upto_seq（读隐含送达）。
 * - 按 person 记 → "该 person 至少一台设备已收到/已读"，不保证其所有设备。
 *   2 人空间足够；将来要"所有设备"需改为按设备记。
 */

export interface ReceiptRow {
  person_id: string
  delivered_upto_seq: number
  read_upto_seq: number
  updated_at: number
}

/** 取当前 device 的 person_id（devices 表是全局表，person 是身份锚点）。 */
function personOfDevice (deviceId: string): string {
  const row = getDb()
    .prepare(`SELECT person_id FROM devices WHERE device_id = ?`)
    .get(deviceId) as { person_id: string } | undefined
  if (!row) throw new ApiError('FORBIDDEN', 'device not found', 403)
  return row.person_id
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
  const { device_id, space_id } = requireSession(token)

  const b = (body ?? {}) as Record<string, unknown>
  const cap = maxSequence(space_id)
  const clamp = (n: number): number => Math.min(n, cap)
  const delivered = clamp(asSeq(b.delivered_upto_seq, 'delivered_upto_seq'))
  const read = clamp(asSeq(b.read_upto_seq, 'read_upto_seq'))
  const personId = personOfDevice(device_id)

  // 单条 SQL 原子 upsert：只前进，且 delivered ≥ read（读隐含送达）。
  // 禁止先读后写——并发上报下会互相覆盖。
  getDb()
    .prepare(
      `INSERT INTO receipts (space_id, person_id, delivered_upto_seq, read_upto_seq, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(space_id, person_id) DO UPDATE SET
         delivered_upto_seq = MAX(receipts.delivered_upto_seq,
                                  MAX(excluded.delivered_upto_seq, excluded.read_upto_seq)),
         read_upto_seq      = MAX(receipts.read_upto_seq, excluded.read_upto_seq),
         updated_at         = excluded.updated_at`
    )
    .run(space_id, personId, delivered, read, Date.now())

  const row = getDb()
    .prepare(
      `SELECT person_id, delivered_upto_seq, read_upto_seq, updated_at
       FROM receipts WHERE space_id = ? AND person_id = ?`
    )
    .get(space_id, personId) as ReceiptRow

  // 通知同空间的其他设备（含自己 person 的其他设备与对方）
  broadcastReceiptUpdated(device_id, {
    person_id: row.person_id,
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
  const { device_id, space_id } = requireSession(token)

  const rows = getDb()
    .prepare(
      `SELECT person_id, delivered_upto_seq, read_upto_seq, updated_at
       FROM receipts WHERE space_id = ? ORDER BY updated_at ASC`
    )
    .all(space_id) as ReceiptRow[]
  return { receipts: rows }
}
