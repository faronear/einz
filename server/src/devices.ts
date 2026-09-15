import { randomInt } from 'node:crypto'
import { getDb, getMeta, setMeta } from './db.js'
import { ApiError, resolveSession } from './auth.js'
import { isActiveDevice, getDevice, type ServerConfig } from './config.js'
import { deviceScopeClause } from './guard.js'
import { broadcastProfileUpdated, getConnectedAt } from './ws.js'

/** 邀请码字符集（去易混字符 0/O/1/I）与格式：5 字符一组，共 4 组。 */
const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
function genInviteCode (len = 20): string {
  let s = ''
  for (let i = 0; i < len; i++)
    s += INVITE_ALPHABET[randomInt(INVITE_ALPHABET.length)]
  return s.match(/.{1,5}/g)!.join('-')
}

/** 分配设备规范 id：客户端传入的 id 已在 devices 表（幂等重登记）→ 原样返回；
 *  否则分配下一个 devN（dev1、dev2…）。设备 id 与密钥解耦（仅标签，见 keys.ts），可安全重命名。 */
function assignDeviceId (clientId: string): string {
  const db = getDb()
  if (
    db
      .prepare(`SELECT device_id FROM devices WHERE device_id = ?`)
      .get(clientId)
  )
    return clientId
  const maxRow = db
    .prepare(
      `SELECT MAX(CAST(SUBSTR(device_id, 4) AS INTEGER)) AS m FROM devices WHERE device_id LIKE 'dev%'`
    )
    .get() as { m: number | null }
  return `dev${(maxRow.m ?? 0) + 1}`
}

/** GET /devices：设备列表（含 person 映射）。
 *  注意：不在本接口刷新调用方 last_seen——last_seen 只由 WS 连接/心跳/断开维护，
 *  否则任何轮询客户端都会让自己"永远新鲜"（对方误判在线，见 chat_page 在线判定）。
 *  范围：**仅本会话可见的设备**（该空间成员；见 guard.deviceScopeClause）——
 *  此前直出全局 devices 表，跨空间泄漏 person/公钥/在线状态（2026-09-15 评审 C2）。 */
export function listDevices (
  cfg: ServerConfig,
  token: string
): { devices: unknown[] } {
  const { device_id, space_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const scope = deviceScopeClause(space_id)
  const rows = getDb()
    .prepare(
      `SELECT d.device_id, d.person_id, d.status, d.last_seen, d.public_key, d.device_name
         FROM devices d
        WHERE ${scope.sql}
        ORDER BY d.created_at`
    )
    .all(...scope.params) as {
    device_id: string
    person_id: string
    status: string
    last_seen: number | null
    public_key: string
    device_name: string
  }[]
  return {
    devices: rows.map(r => ({
      ...r,
      connected_at: getConnectedAt(r.device_id)
    }))
  }
}

/** DELETE /devices/:id：撤销设备（白名单移除 + 清 Push Token + 清会话，PROTOCOL.md §7.2）。
 *  2026-09-14 决策：不再返回 `key_rotation_required`——产品不做密钥轮换（无端侧入口、
 *  分发链路不成立），该字段只会暗示一个不存在的能力，见 docs/SECURITY.md。 */
export function revokeDevice (
  cfg: ServerConfig,
  token: string,
  targetDeviceId: string
): { ok: true } {
  const { device_id: callerId } = resolveSession(token)
  if (!isActiveDevice(cfg, callerId))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const target = getDevice(cfg, targetDeviceId)
  if (!target) throw new ApiError('NOT_FOUND', 'device not found', 404)
  if (target.device_id === callerId)
    throw new ApiError('INVALID_REQUEST', 'cannot revoke self', 400)

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
 * POST /devices/enroll：设备动态登记（免认证——准入令牌即"邀请码"或"首设备自举"）。
 * - **首设备自举**：空间还没有任何 active 设备时，免邀请码——第一个登记的设备
 *   自动成为空间创建者（person 客户端自报，写入 creator_person_id，拥有生成邀请码权限）；
 * - **常规登记**：空间已有设备后，凭创建者生成的一次性邀请码加入（person 取自
 *   邀请码记录，不信任客户端提交）；
 * - 登记写入 devices 表（status='active'），判定源已是数据库，登记后立即生效、无需重启；
 * - 已登记设备幂等返回成功；被撤销设备拒绝复活。
 */
export function enrollDevice (
  cfg: ServerConfig,
  body: unknown
): { ok: true; device_id: string; person_id: string; space_id: string } {
  const b = (body ?? {}) as {
    device_id?: string
    public_key?: string
    invite_code?: string
    person_name?: string
    partner_name?: string
    person_gender?: string
    partner_gender?: string
    device_name?: string
    person_id?: string
  }
  const deviceId = (b.device_id ?? '').trim()
  const publicKey = (b.public_key ?? '').trim()
  const inviteCode = (b.invite_code ?? '').trim()

  const db = getDb()
  const now = Date.now()

  // 0) 首设备自举：空间 0 台 active 设备 → 免邀请码，登记为创建者。
  //    person 用规范 id（personA），自定义名称（person_name，如 lukas）存 meta 名称表
  const activeCount = (
    db
      .prepare(`SELECT COUNT(*) AS c FROM devices WHERE status = 'active'`)
      .get() as { c: number }
  ).c
  if (activeCount === 0) {
    if (!publicKey) {
      // device_id 可空：客户端登记前无 id（登记后由服务端分配规范 id dev1/dev2…）
      throw new ApiError('INVALID_REQUEST', 'public_key 必填', 400)
    }
    const assignedId = assignDeviceId(deviceId) // 首个设备 → dev1（规范 id）
    const deviceName = (b.device_name ?? '').trim() || assignedId
    const personId = 'personA'
    const personName = (b.person_name ?? '').trim() || 'personA'
    const existing = db
      .prepare(`SELECT status FROM devices WHERE device_id = ?`)
      .get(assignedId) as { status: string } | undefined
    if (existing && existing.status === 'revoked') {
      throw new ApiError('FORBIDDEN', 'device revoked, cannot re-enroll', 403)
    }
    if (!existing) {
      db.prepare(
        `INSERT INTO devices (device_id, person_id, public_key, status, device_name, created_at) VALUES (?, ?, ?, 'active', ?, ?)`
      ).run(assignedId, personId, publicKey, deviceName, now)
    }
    setMeta('creator_person_id', personId) // 创建者标记（规范 id）
    setMeta(`person_name:${personId}`, personName) // 名称表：personA → lukas
    // 性别表（meta person_gender:*，male/female；未提供不落 meta，/health 不下发）
    const personGender = (b.person_gender ?? '').trim()
    if (personGender) setMeta(`person_gender:${personId}`, personGender)
    // 第二用户预置名（首设备创建时可选询问；跳过/未提供 → 落规范默认 personB，
    // 后续设备启动引导即可按名称表直接选 personA/personB 身份）
    const partnerName = (b.partner_name ?? '').trim()
    setMeta('person_name:personB', partnerName || 'personB')
    const partnerGender = (b.partner_gender ?? '').trim()
    if (partnerGender) setMeta('person_gender:personB', partnerGender)
    console.log(
      `[einz] 首设备自举成功: device=${assignedId}（${deviceName}）person=${personId}（${personName}，空间创建者）partner=${
        partnerName || 'personB'
      }`
    )
    return {
      ok: true,
      device_id: assignedId,
      person_id: personId,
      space_id: "" // v2：服务端无全局 space（空间由客户端 create/join 建立，登记后经 session 绑定）
    }
  }

  // 1) 常规登记：邀请码必填（空间已有设备）
  if (!inviteCode) {
    throw new ApiError(
      'INVALID_REQUEST',
      'device_id / public_key / invite_code 必填（首个设备免邀请码自举）',
      400
    )
  }

  // 校验邀请码：存在 + pending + 未过期
  const invite = db
    .prepare(
      `SELECT person_id, status, expires_at FROM invites WHERE invite_code = ?`
    )
    .get(inviteCode) as
    | { person_id: string; status: string; expires_at: number }
    | undefined
  if (!invite) throw new ApiError('INVALID_INVITE', '邀请码不存在', 400)
  if (invite.status !== 'pending')
    throw new ApiError('INVALID_INVITE', '邀请码已使用', 400)
  if (invite.expires_at < now) {
    db.prepare(
      `UPDATE invites SET status = 'expired' WHERE invite_code = ?`
    ).run(inviteCode)
    throw new ApiError(
      'INVALID_INVITE',
      '邀请码已过期，请联系创建者重新生成',
      400
    )
  }

  // 2) person 决定：客户端可指定 person_id（后续设备引导时询问用户是
  //    personA/personB），未指定则用邀请码绑定的 person
  const personId = (b.person_id ?? '').trim() || invite.person_id
  if (personId !== 'personA' && personId !== 'personB') {
    throw new ApiError(
      'INVALID_REQUEST',
      'person_id 必须是 personA 或 personB',
      400
    )
  }
  // personA 必须已入网（第一个创建人已自举）——不能凭空登记为第一个人
  if (personId === 'personA') {
    const personAActive = db
      .prepare(
        `SELECT COUNT(*) AS c FROM devices WHERE person_id = 'personA' AND status = 'active'`
      )
      .get() as { c: number }
    if (personAActive.c === 0) {
      throw new ApiError(
        'FORBIDDEN',
        'personA（第一个创建人）尚未入网，无法登记为其设备',
        403
      )
    }
  }
  // 两 person 上限：空间内 distinct person ≤2；指定的 person 若是全新
  // （空间已满 2 个 person）则拒绝——同一个人多台设备不受限（person 已有 active 设备）。
  const personCount = db
    .prepare(
      `SELECT COUNT(DISTINCT person_id) AS c FROM devices WHERE status = 'active'`
    )
    .get() as { c: number }
  const thisPersonActive = db
    .prepare(
      `SELECT COUNT(*) AS c FROM devices WHERE person_id = ? AND status = 'active'`
    )
    .get(personId) as { c: number }
  if (personCount.c >= 2 && thisPersonActive.c === 0) {
    throw new ApiError(
      'FORBIDDEN',
      '空间最多两个 person（当前已满），新人员请联系创建者调整白名单',
      403
    )
  }

  // 3) 登记设备（幂等：已 active 直接成功；revoked 拒绝复活）
  const assignedId = assignDeviceId(deviceId) // 服务端分配规范 id（dev2、dev3…）
  const deviceName = (b.device_name ?? '').trim() || assignedId
  const existing = db
    .prepare(`SELECT status FROM devices WHERE device_id = ?`)
    .get(assignedId) as { status: string } | undefined
  if (existing && existing.status === 'revoked') {
    throw new ApiError('FORBIDDEN', 'device revoked, cannot re-enroll', 403)
  }
  if (!existing) {
    db.prepare(
      `INSERT INTO devices (device_id, person_id, public_key, status, device_name, created_at) VALUES (?, ?, ?, 'active', ?, ?)`
    ).run(assignedId, personId, publicKey, deviceName, now)
  }
  // 登记时设置/更新 person_name（后续设备引导时用户选择的身份名称）。
  // 未提供自定义名时默认落规范 id（如 personB → personB），保证 /health 名称表
  // 始终有值（_probePersonNames['personB'] 可检测到）——但已有名称
  // （如邀请时预设的 Alice）不会被默认值覆盖
  const personName = (b.person_name ?? '').trim()
  if (personName) {
    setMeta(`person_name:${personId}`, personName)
  } else if (!getMeta(`person_name:${personId}`)) {
    setMeta(`person_name:${personId}`, personId)
  }

  // 4) 标记邀请码已用（一次性）
  db.prepare(
    `UPDATE invites SET status = 'used', used_by = ?, used_at = ? WHERE invite_code = ?`
  ).run(assignedId, now, inviteCode)

  return {
    ok: true,
    device_id: assignedId,
    person_id: personId,
    space_id: "" // v2：服务端无全局 space（空间由客户端 create/join 建立，登记后经 session 绑定）
  }
}

/**
 * POST /invites：创建者生成一次性邀请码（白名单外新设备加入用）。
 * - 权限：仅创建者（首设备自举登记的 person，meta 里 creator_person_id）可生成；
 *   旧库未自举（无 creator 标记）时放宽为任一 active 设备（向后兼容）。
 * - person_id 必填（给谁的邀请）；两 person 上限预检：新 person 且空间已满 2 → 拒绝。
 */
export function createInvite (
  cfg: ServerConfig,
  token: string,
  body: unknown
): { invite_code: string; person_id: string; expires_at: number } {
  const { device_id: callerId } = resolveSession(token)
  if (!isActiveDevice(cfg, callerId))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const b = (body ?? {}) as {
    person_id?: string
    person_name?: string
    hours?: number
  }
  const personId = (b.person_id ?? '').trim()
  if (personId !== 'personA' && personId !== 'personB') {
    throw new ApiError(
      'INVALID_REQUEST',
      'person_id 必须是规范 id: personA 或 personB',
      400
    )
  }
  const personName = (b.person_name ?? '').trim()
  const hours = Math.min(Math.max(Math.floor(b.hours ?? 24), 1), 168)

  const db = getDb()
  // 权限：任一 active 设备均可生成邀请码（第一/第二使用者都能邀请自己的其他设备）；
  // 旧库无 active 设备时（未自举）拒绝（空间未初始化）
  const caller = db
    .prepare(
      `SELECT person_id FROM devices WHERE device_id = ? AND status = 'active'`
    )
    .get(callerId) as { person_id: string } | undefined
  if (!caller)
    throw new ApiError('FORBIDDEN', '仅空间成员可生成邀请码（设备未激活）', 403)

  // 两 person 上限预检：新 person（无 active 设备）且空间已满 2 → 拒绝
  const personCount = db
    .prepare(
      `SELECT COUNT(DISTINCT person_id) AS c FROM devices WHERE status = 'active'`
    )
    .get() as { c: number }
  const thisPersonActive = db
    .prepare(
      `SELECT COUNT(*) AS c FROM devices WHERE person_id = ? AND status = 'active'`
    )
    .get(personId) as { c: number }
  if (personCount.c >= 2 && thisPersonActive.c === 0) {
    throw new ApiError('FORBIDDEN', '空间最多两个 person（当前已满）', 403)
  }
  // 名称表：新 person 首次被邀请时记录自定义名称（如 personB → Alice）
  if (personName) {
    setMeta(`person_name:${personId}`, personName)
  }

  const code = genInviteCode()
  const expiresAt = Date.now() + hours * 3600_000
  db.prepare(
    `INSERT INTO invites (invite_code, person_id, status, created_at, expires_at) VALUES (?, ?, 'pending', ?, ?)`
  ).run(code, personId, Date.now(), expiresAt)
  console.log(
    `[einz] 生成邀请码: person=${personId}${
      personName ? `（${personName}）` : ''
    } hours=${hours}`
  )
  return { invite_code: code, person_id: personId, expires_at: expiresAt }
}

/**
 * POST /devices/name：更新本设备名称（已登记设备 TUI 里改名后同步到后台，显示层用）。
 * - 认证：session token（bearer）；仅 active 设备可改自己的名称。
 */
export function updateDeviceName (
  cfg: ServerConfig,
  token: string,
  body: unknown
): { ok: true } {
  const { device_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const b = (body ?? {}) as { device_name?: string }
  const deviceName = (b.device_name ?? '').trim()
  if (!deviceName)
    throw new ApiError('INVALID_REQUEST', 'device_name 不能为空', 400)

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
  cfg: ServerConfig,
  token: string,
  body: unknown
): { ok: true } {
  const { device_id, space_id } = resolveSession(token)
  if (!isActiveDevice(cfg, device_id))
    throw new ApiError('FORBIDDEN', 'device not in whitelist', 403)

  const b = (body ?? {}) as { person_name?: string }
  const personName = (b.person_name ?? '').trim()
  if (!personName)
    throw new ApiError('INVALID_REQUEST', 'person_name 不能为空', 400)

  const row = getDb()
    .prepare(`SELECT person_id FROM devices WHERE device_id = ?`)
    .get(device_id) as { person_id: string } | undefined
  if (!row) throw new ApiError('NOT_FOUND', 'device not found', 404)

  setMeta(`person_name:${row.person_id}`, personName)
  // v2：名称表同步 space_members.display_name——GET /space 从该表读名称
  // （90ec740 起不再读 meta）。漏同步则改名后名称表仍是旧名：自己右上角名字
  // 不刷新、对方改名后我方名称表被旧值覆盖（回归 v1 的单一数据源一致性）。
  if (space_id != null && row.person_id) {
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
