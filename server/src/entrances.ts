import { getDb } from './db.js'
import { ApiError } from './auth.js'
import { getEntrance } from './config.js'
import { assertEntranceName } from './entranceName.js'
import { assertInstallUid } from './installUid.js'
import { assertMemberName } from './memberName.js'
import { entranceScopeClause, isSpaceMember, requireSession } from './guard.js'
import { assertSpacePassphrase } from './escrow.js'
import { broadcastProfileUpdated, forgetEntranceConnection, getConnectedAt, getOnlineSince } from './ws.js'

/** GET /entrances：通道列表（含 member 映射）。
 *  注意：不在本接口刷新调用方 last_seen——last_seen 只由 WS 连接/心跳/断开维护，
 *  否则任何轮询客户端都会让自己"永远新鲜"（对方误判在线，见 chat_page 在线判定）。
 *  范围：**仅本会话可见的通道**（该空间成员；见 guard.entranceScopeClause）——
 *  此前直出全局 entrances 表，跨空间泄漏 member/公钥/在线状态（2026-09-15 评审 C2）。
 *  刻意**不返回 public_key**（2026-09-15 评审 C5）：通道公钥是密码学标识，
 *  列表接口没有使用它的场景（challenge 由服务端用公钥密封，客户端用不到对端公钥），
 *  少一个可被批量采集的字段就少一分元数据面。 */
export function listEntrances (
  token: string
): { entrances: unknown[] } {
  const { entrance_id, space_id } = requireSession(token)

  const scope = entranceScopeClause(space_id)
  const rows = getDb()
    .prepare(
      `SELECT d.entrance_id, d.member_id, d.status, d.last_seen, d.entrance_name
         FROM entrances d
        WHERE ${scope.sql}
        ORDER BY d.created_at`
    )
    .all(...scope.params) as {
    entrance_id: string
    member_id: string
    status: string
    last_seen: number | null
    entrance_name: string
  }[]
  return {
    entrances: rows.map(r => ({
      ...r,
      connected_at: getConnectedAt(r.entrance_id),
      // 进入在线态的时刻（重连不刷新）：客户端据此按上线顺序排列对端在线通道
      online_since: getOnlineSince(r.entrance_id)
    }))
  }
}

/** POST /entrances/:id/revoke：撤销**本空间内**的另一条通道
 *  （白名单移除 + 清 Push Token + 清会话，PROTOCOL.md §7.2）。
 *
 * 授权规则（老板 2026-09-16 定稿）：
 * 1. **同 space 内可互撤**——不限于"同一 member 的另一条通道"：A 的手机丢了、A 又没有
 *    第二条通道时，伴侣 B 也能替他撤掉那条（此前的实现是"任何在册通道能撤任何通道"，
 *    连空间都不校验；而文档写的是"仅限同 member"，代码比文档更宽）；
 * 2. **每次撤销都要校验密保口令**（`assertSpacePassphrase`：argon2id + 失败限速）——
 *    撤销会让对方客户端**自毁本地数据**，属于不可逆的破坏性操作，必须由"口令持有者"
 *    授权；这样即使伴侣的一条通道被入侵，仅凭 session 也清不掉另一方的通道。
 * 3. 不能撤自己（400）：撤销自己等于就地自毁，产品上没有这个场景，留个明确的报错。
 *
 * 2026-09-14 决策：不返回 `key_rotation_required`——产品不做密钥轮换（无端侧入口、
 * 分发链路不成立），该字段只会暗示一个不存在的能力，见 docs/SECURITY.md。 */
export async function revokeEntrance (
  token: string,
  targetEntranceId: string,
  passphrase: unknown
): Promise<{ ok: true }> {
  const caller = requireSession(token)

  const target = getEntrance(targetEntranceId)
  if (!target) throw new ApiError('NOT_FOUND', 'entrance not found', 404)
  if (target.entrance_id === caller.entrance_id)
    throw new ApiError('INVALID_REQUEST', 'cannot revoke self', 400)
  // 目标通道必须属于**本会话所在空间**（entrances 表没有 space 列，空间归属走
  // entrances.member_id → space_members）
  if (target.member_id.length === 0 || !isSpaceMember(caller.space_id, target.member_id)) {
    throw new ApiError('FORBIDDEN', 'target entrance is not in this space', 403)
  }
  // 口令校验放在"目标合法性"之后：错误的目标不该消耗口令尝试预算
  await assertSpacePassphrase(caller.space_id, passphrase)

  const db = getDb()
  const now = Date.now()
  db.prepare(
    `UPDATE entrances SET status = 'revoked', last_seen = ? WHERE entrance_id = ?`
  ).run(now, targetEntranceId)
  db.prepare(`DELETE FROM push_tokens WHERE entrance_id = ?`).run(targetEntranceId)
  db.prepare(`DELETE FROM sessions WHERE entrance_id = ?`).run(targetEntranceId)

  return { ok: true }
}

/** POST /entrances/retire：**本机自助退役**——把自己从服务端注销，回到从未入网的样子。
 *
 * 与 §7.2 撤销（revoke）的区别：
 * - **目标恒为自己**：撤销是收拾别人的通道（自己被收拾要走对方那条发起），退役是收拾自己；
 * - **不校验空间口令**：这里是"注销我自己"，session 就是所有权证明；而且客户端在调用它
 *   之前已经过了「输入通道名 + 本机 PIN」的本地闸门。口令是**共享**给伴侣的加入凭证，
 *   不该获得"销毁我这条通道"的权力（老板 2026-09-21 定稿）；
 * - **不发 `entrance.revoked`**（见 ws.forgetEntranceConnection）：远程触发擦除的授权信号仍然
 *   只有口令干得动（撤销路径），本接口不打开这条旁路。
 *
 * 存在的理由：客户端"重置本通道"原先纯本地清数据，服务端这条通道的注册表项、Push Token、
 *   会话全都留着——对方 /entrances 里是一台永远在线的幽灵，而且 revoke 禁止自撤，谁也删不掉它
 *   （老板 2026-09-21 定：一并处理）。
 *
 * 清理范围（比 revoke 多一条 challenges）：
 * - entrances：置 status='revoked'、**不删行**（messages.sender_entrance_id 会失去归属，
 *   且配置层 getEntranceStatus 只认 revoked，新增状态会被判成 active 而"复活"）；
 * - push_tokens（否则继续给一条已经不存在的通道推送）、sessions（持有即为登录态）、
 *   challenges（无外键，遗留的待签会话可重放签发新 session，让幽灵复活）；
 * - connection_events / entrance_activity 是**只追加审计表**，刻意保留——"这条通道来过"
 *   是事后追溯的依据，且它们不参与任何业务语义。
 */
export function retireEntrance(token: string): { ok: true } {
  // 先鉴权（此刻 status 还是 active）：requireSession 自带"已撤销通道不得操作"
  const caller = requireSession(token)

  const db = getDb()
  db.prepare(`UPDATE entrances SET status = 'revoked', last_seen = 0 WHERE entrance_id = ?`).run(
    caller.entrance_id
  )
  db.prepare(`DELETE FROM push_tokens WHERE entrance_id = ?`).run(caller.entrance_id)
  db.prepare(`DELETE FROM sessions WHERE entrance_id = ?`).run(caller.entrance_id)
  db.prepare(`DELETE FROM challenges WHERE entrance_id = ?`).run(caller.entrance_id)

  // 自己的 WS 连接还在 conns 里：摘掉并让对端立刻看到下线（不发自毁帧，见 ws 注释）
  forgetEntranceConnection(caller.entrance_id)

  return { ok: true }
}

/**
 * POST /entrances/install-uid：补登本通道的安装级标识（多空间）。
 *
 * 存在的理由：`install_uid` 是随 create/join 一起上报的，但**存量通道**（多空间
 * 上线前入网的那批，生产上已有人在用）不会再走一次入网 → 由客户端在进聊天页时
 * 幂等补登一次。同一个 uid 下、不同空间的 entrance_id 由此在服务端对齐。
 *
 * 语义边界（老板 2026-09-22 定）：
 * - 只影响**本会话对应的那一行**（一个空间的虚拟通道）；客户端在别的空间里
 *   再补登一次才有那两行。不需要、也不该由服务端去猜。
 * - 不是安全边界：改自己的 install_uid 不改变任何权限——它只用于服务端内部认知
 *   （审计/运维/将来"整机退役"），**不参与破坏性操作的授权或范围判断**。
 * - 幂等：重复调用写同一个值。
 */
export function setInstallUid (token: string, body: unknown): { ok: true } {
  const { entrance_id } = requireSession(token)
  const b = (body ?? {}) as { install_uid?: unknown }
  const uid = assertInstallUid(b.install_uid)
  getDb().prepare(`UPDATE entrances SET install_uid = ? WHERE entrance_id = ?`).run(uid, entrance_id)
  return { ok: true }
}

/**
 * POST /entrances/name：更新本通道名称（已登记通道 TUI 里改名后同步到后台，显示层用）。
 * - 认证：session token（bearer）；仅 active 通道可改自己的名称。
 */
export function updateEntranceName (
  token: string,
  body: unknown
): { ok: true } {
  const { entrance_id } = requireSession(token)

  const b = (body ?? {}) as { entrance_name?: string }
  const entranceName = (b.entrance_name ?? '').trim()
  // 通道名字符白名单 + 长度上限（老板 2026-09-16）：用户主动改名 → 不合规直接
  // 400 让客户端提示重输，不悄悄改写他的输入（create/join 的自动名走
  // normalizeEntranceName 消毒，见 entranceName.ts）
  assertEntranceName(entranceName)

  getDb()
    .prepare(`UPDATE entrances SET entrance_name = ? WHERE entrance_id = ?`)
    .run(entranceName, entrance_id)
  console.log(`[einz] 更新通道名称: entrance=${entrance_id}（${entranceName}）`)
  broadcastProfileUpdated(entrance_id, { entrance_id, entrance_name: entranceName })
  return { ok: true }
}

/**
 * POST /members/name：更新本通道的 member 显示名（/rename 命令，显示层用）。
 * - 认证：session token（bearer）；仅 active 通道可改自己 member 的名称。
 */
export function updateMemberName (
  token: string,
  body: unknown
): { ok: true } {
  const { entrance_id, space_id } = requireSession(token)

  const b = (body ?? {}) as { member_name?: string }
  const memberName = (b.member_name ?? '').trim()
  // 用户名称白名单 + 长度上限（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，
  // 最长 32；不合规直接 400 让客户端提示重输（名字是用户自己输的，不静默改写）
  assertMemberName(memberName)

  const row = getDb()
    .prepare(`SELECT member_id FROM entrances WHERE entrance_id = ?`)
    .get(entrance_id) as { member_id: string } | undefined
  if (!row) throw new ApiError('NOT_FOUND', 'entrance not found', 404)

  // 名称的**唯一数据源是 space_members.display_name**（GET /space 从这里读）。
  // v1 时代还写一份 meta `person_name:*`，收敛后删除——两处写必然漂移。
  if (row.member_id) {
    getDb()
      .prepare(`UPDATE space_members SET display_name = ? WHERE space_id = ? AND member_id = ?`)
      .run(memberName, space_id, row.member_id)
  }
  console.log(
    `[einz] 更新 member 名称: member=${row.member_id}（${memberName}）`
  )
  broadcastProfileUpdated(entrance_id, {
    entrance_id,
    member_id: row.member_id,
    member_name: memberName
  })
  return { ok: true }
}
