import { getDb } from './db.js'
import { ApiError } from './auth.js'
import { getDevice } from './config.js'
import { assertDeviceName } from './deviceName.js'
import { assertPersonName } from './personName.js'
import { deviceScopeClause, isSpaceMember, requireSession } from './guard.js'
import { assertSpacePassphrase } from './escrow.js'
import { broadcastProfileUpdated, getConnectedAt, getOnlineSince } from './ws.js'

/** GET /devices：设备列表（含 person 映射）。
 *  注意：不在本接口刷新调用方 last_seen——last_seen 只由 WS 连接/心跳/断开维护，
 *  否则任何轮询客户端都会让自己"永远新鲜"（对方误判在线，见 chat_page 在线判定）。
 *  范围：**仅本会话可见的设备**（该空间成员；见 guard.deviceScopeClause）——
 *  此前直出全局 devices 表，跨空间泄漏 person/公钥/在线状态（2026-09-15 评审 C2）。
 *  刻意**不返回 public_key**（2026-09-15 评审 C5）：设备公钥是密码学标识，
 *  列表接口没有使用它的场景（challenge 由服务端用公钥密封，客户端用不到对端公钥），
 *  少一个可被批量采集的字段就少一分元数据面。 */
export function listDevices (
  token: string
): { devices: unknown[] } {
  const { device_id, space_id } = requireSession(token)

  const scope = deviceScopeClause(space_id)
  const rows = getDb()
    .prepare(
      `SELECT d.device_id, d.person_id, d.status, d.last_seen, d.device_name
         FROM devices d
        WHERE ${scope.sql}
        ORDER BY d.created_at`
    )
    .all(...scope.params) as {
    device_id: string
    person_id: string
    status: string
    last_seen: number | null
    device_name: string
  }[]
  return {
    devices: rows.map(r => ({
      ...r,
      connected_at: getConnectedAt(r.device_id),
      // 进入在线态的时刻（重连不刷新）：客户端据此按上线顺序排列对端在线设备
      online_since: getOnlineSince(r.device_id)
    }))
  }
}

/** POST /devices/:id/revoke：撤销**本空间内**的另一台设备
 *  （白名单移除 + 清 Push Token + 清会话，PROTOCOL.md §7.2）。
 *
 * 授权规则（老板 2026-09-16 定稿）：
 * 1. **同 space 内可互撤**——不限于"同一 person 的另一台设备"：A 的手机丢了、A 又没有
 *    第二台设备时，伴侣 B 也能替他撤掉那台（此前的实现是"任何在册设备能撤任何设备"，
 *    连空间都不校验；而文档写的是"仅限同 person"，代码比文档更宽）；
 * 2. **每次撤销都要校验密保口令**（`assertSpacePassphrase`：argon2id + 失败限速）——
 *    撤销会让对方客户端**自毁本地数据**，属于不可逆的破坏性操作，必须由"口令持有者"
 *    授权；这样即使伴侣的一台设备被入侵，仅凭 session 也清不掉另一方的设备。
 * 3. 不能撤自己（400）：撤销自己等于就地自毁，产品上没有这个场景，留个明确的报错。
 *
 * 2026-09-14 决策：不返回 `key_rotation_required`——产品不做密钥轮换（无端侧入口、
 * 分发链路不成立），该字段只会暗示一个不存在的能力，见 docs/SECURITY.md。 */
export async function revokeDevice (
  token: string,
  targetDeviceId: string,
  passphrase: unknown
): Promise<{ ok: true }> {
  const caller = requireSession(token)

  const target = getDevice(targetDeviceId)
  if (!target) throw new ApiError('NOT_FOUND', 'device not found', 404)
  if (target.device_id === caller.device_id)
    throw new ApiError('INVALID_REQUEST', 'cannot revoke self', 400)
  // 目标设备必须属于**本会话所在空间**（devices 表没有 space 列，空间归属走
  // devices.person_id → space_members）
  if (target.person_id.length === 0 || !isSpaceMember(caller.space_id, target.person_id)) {
    throw new ApiError('FORBIDDEN', 'target device is not in this space', 403)
  }
  // 口令校验放在"目标合法性"之后：错误的目标不该消耗口令尝试预算
  await assertSpacePassphrase(caller.space_id, passphrase)

  const db = getDb()
  const now = Date.now()
  db.prepare(
    `UPDATE devices SET status = 'revoked', last_seen = ? WHERE device_id = ?`
  ).run(now, targetDeviceId)
  db.prepare(`DELETE FROM push_tokens WHERE device_id = ?`).run(targetDeviceId)
  db.prepare(`DELETE FROM sessions WHERE device_id = ?`).run(targetDeviceId)

  return { ok: true }
}

/**
 * POST /devices/name：更新本设备名称（已登记设备 TUI 里改名后同步到后台，显示层用）。
 * - 认证：session token（bearer）；仅 active 设备可改自己的名称。
 */
export function updateDeviceName (
  token: string,
  body: unknown
): { ok: true } {
  const { device_id } = requireSession(token)

  const b = (body ?? {}) as { device_name?: string }
  const deviceName = (b.device_name ?? '').trim()
  // 设备名字符白名单 + 长度上限（老板 2026-09-16）：用户主动改名 → 不合规直接
  // 400 让客户端提示重输，不悄悄改写他的输入（create/join 的自动名走
  // normalizeDeviceName 消毒，见 deviceName.ts）
  assertDeviceName(deviceName)

  getDb()
    .prepare(`UPDATE devices SET device_name = ? WHERE device_id = ?`)
    .run(deviceName, device_id)
  console.log(`[einz] 更新设备名称: device=${device_id}（${deviceName}）`)
  broadcastProfileUpdated(device_id, { device_id, device_name: deviceName })
  return { ok: true }
}

/**
 * POST /devices/person-name：更新本设备的 person 显示名（/rename 命令，显示层用）。
 * - 认证：session token（bearer）；仅 active 设备可改自己 person 的名称。
 */
export function updatePersonName (
  token: string,
  body: unknown
): { ok: true } {
  const { device_id, space_id } = requireSession(token)

  const b = (body ?? {}) as { person_name?: string }
  const personName = (b.person_name ?? '').trim()
  // 用户名称白名单 + 长度上限（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，
  // 最长 32；不合规直接 400 让客户端提示重输（名字是用户自己输的，不静默改写）
  assertPersonName(personName)

  const row = getDb()
    .prepare(`SELECT person_id FROM devices WHERE device_id = ?`)
    .get(device_id) as { person_id: string } | undefined
  if (!row) throw new ApiError('NOT_FOUND', 'device not found', 404)

  // 名称的**唯一数据源是 space_members.display_name**（GET /space 从这里读）。
  // v1 时代还写一份 meta `person_name:*`，收敛后删除——两处写必然漂移。
  if (row.person_id) {
    getDb()
      .prepare(`UPDATE space_members SET display_name = ? WHERE space_id = ? AND person_id = ?`)
      .run(personName, space_id, row.person_id)
  }
  console.log(
    `[einz] 更新 person 名称: person=${row.person_id}（${personName}）`
  )
  broadcastProfileUpdated(device_id, {
    device_id,
    person_id: row.person_id,
    person_name: personName
  })
  return { ok: true }
}
