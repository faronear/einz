import { WebSocketServer, WebSocket } from "ws";
import { optionalBearerToken, requireSession } from "./guard.js";
import type { MessageEnvelope } from "./messages.js";
import { getDb } from "./db.js";
import { logConnection, metaOf, type RequestMeta } from "./audit.js";
import { PROTOCOL_VERSION } from "./protocolVersion.js";

interface Conn {
  ws: WebSocket;
  entranceId: string;
  memberId: string | null; // 通道归属身份（同一人的多通道共享 member_id）
  spaceId: string; // 连接绑定的 Space（会话必带 space）
  alive: boolean;
  connectedAt: number; // 本次 WS 连接建立时刻（ms）——/entrances 显示"上线时间"
  onlineSince: number; // 进入在线态的时刻（ms）——与 connectedAt 的区别：重连
  // （被新连接踢掉后又连上）不刷新它，只有"从无连接变成有连接"才置 now。
  // 用途：客户端按"上线顺序"排列对端的多条在线通道（最新上线在最前），
  // 重连不应让通道跳到队首（老板 2026-09-16）。
  meta: RequestMeta; // 来源 IP / UA（建连时的 req），审计落库用
  timedOut: boolean; // 已被心跳判定为超时（close 时据此记 heartbeat_timeout）
}

const conns = new Map<string, Conn>(); // entrance_id → 连接（一人一机 V1：每通道至多 1 条连接）

/** 通道当前 WS 连接的建立时刻（ms；离线通道返回 null）。 */
export function getConnectedAt(entranceId: string): number | null {
  return conns.get(entranceId)?.connectedAt ?? null;
}

/** 通道进入在线态的时刻（ms；离线返回 null）——重连不刷新，见 Conn.onlineSince。 */
export function getOnlineSince(entranceId: string): number | null {
  return conns.get(entranceId)?.onlineSince ?? null;
}

/** 发起方通道所属 Space：优先其在线连接；**不在线时回退查 sessions**
 *  （同一通道可能有多条历史会话——取最新的非空 space_id）。
 *  背景：广播此前只认发起方的在线连接（sameSpace），发起方 WS 不在（移动端切
 *  后台/断线）就一条都不发 → 对端改名/换头像后 TUI 一直显示旧名
 *  （老板 2026-09-11 实测）。 */
function spaceOfEntrance(entranceId: string): string | null {
  const online = conns.get(entranceId)?.spaceId;
  if (online != null && online !== "") return online;
  const row = getDb()
    .prepare(
      `SELECT space_id FROM sessions WHERE entrance_id = ? AND space_id IS NOT NULL ORDER BY created_at DESC LIMIT 1`
    )
    .get(entranceId) as { space_id: string } | undefined;
  return row?.space_id ?? null;
}

/** 广播只发给**另一个人**的在线通道：同一 member 的多条通道（同一人的手机+电脑）
 *  不算"对方"——此前只排除发起通道本身，自己的第二条通道一上线，第一条就把
 *  对方灯点亮（老板 2026-09-16 实测：B 从未加入却显示在线）。
 *  payload 带 member_id：客户端（可能连着旧版服务端）据此二次过滤。
 *  peer.online 另带 online_since：接收方据此把该通道插到"在线通道列表"的正确
 *  位置（按上线顺序，最新上线在最前），省掉一次 /entrances 往返（老板 2026-09-16）。 */
function broadcastPeerStatus(exceptEntranceId: string, type: "peer.online" | "peer.offline"): void {
  const origin = conns.get(exceptEntranceId);
  const spaceId = origin?.spaceId ?? null;
  if (spaceId == null) return;
  const originMemberId = origin?.memberId ?? null;
  const payload: Record<string, unknown> = {
    entrance_id: exceptEntranceId,
    member_id: originMemberId,
  };
  if (type === "peer.online") payload.online_since = origin?.onlineSince ?? null;
  const frame = JSON.stringify({ id: 0, type, payload });
  for (const [entranceId, conn] of conns) {
    if (entranceId === exceptEntranceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (originMemberId != null && conn.memberId === originMemberId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) conn.ws.send(frame);
  }
}

/** 空间口令已被重设：通知其余在线通道（客户端收到后只发通知不弹窗）。 */
export function broadcastPassphraseRotated(exceptEntranceId: string): void {
  const spaceId = spaceOfEntrance(exceptEntranceId);
  if (spaceId == null) return;
  for (const [entranceId, conn] of conns) {
    if (entranceId === exceptEntranceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(
        JSON.stringify({ id: 0, type: "passphrase.rotated", payload: { entrance_id: exceptEntranceId } })
      );
    }
  }
}

/** 消息回执（已送达/已读）更新：通知同 Space 的其他通道。
 *  用 spaceOfEntrance（带 sessions 兜底）——上报通道可能没有活跃 WS 连接
 *  （移动端切后台后仍在同步）。 */
export function broadcastReceiptUpdated(
  exceptEntranceId: string,
  payload: { member_id: string; delivered_upto_seq: number; read_upto_seq: number }
): void {
  const spaceId = spaceOfEntrance(exceptEntranceId);
  if (spaceId == null) return;
  for (const [entranceId, conn] of conns) {
    if (entranceId === exceptEntranceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type: "receipt.updated", payload }));
    }
  }
}

/** 改名/改通道名：通知其余在线通道立即更新对方名称（App/TUI 顶部条）。 */
export function broadcastProfileUpdated(
  exceptEntranceId: string,
  payload: { member_id?: string; entrance_id: string; member_name?: string; entrance_name?: string }
): void {
  const spaceId = spaceOfEntrance(exceptEntranceId);
  if (spaceId == null) return;
  for (const [entranceId, conn] of conns) {
    if (entranceId === exceptEntranceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type: "profile.updated", payload }));
    }
  }
}

/** 注册 WS 服务（PROTOCOL.md §8）。 */
export function attachWs(wss: WebSocketServer): void {
  wss.on("connection", (ws, req) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const pv = url.searchParams.get("pv");
    // H4 修复（2026-09-15 评审）：token 从 Authorization 头取，**不再**从 URL
    // query 读——URL 会进反代 access log / 代理缓存 / 浏览器历史，会话凭证不该
    // 落在这些地方（此前是 `?pv=1&token=<session_token>`）。
    const token = optionalBearerToken(req);

    if (pv !== PROTOCOL_VERSION) {
      ws.close(4400, "PROTOCOL_VERSION_MISMATCH");
      return;
    }

    let entranceId: string;
    let spaceId: string;
    let memberId: string | null;
    try {
      // requireSession 同时完成：会话有效 + 通道在册 + 会话带 space（v1 收敛后必备）
      const sess = requireSession(token);
      entranceId = sess.entrance_id;
      spaceId = sess.space_id;
      // 通道归属身份：peer 广播据此跳过同一人的其它通道（同人≠对方）
      memberId = sess.member_id === "" ? null : sess.member_id;
    } catch {
      ws.close(4401, "UNAUTHORIZED");
      return;
    }
    // V1 一人一机：重复连接踢掉旧连接
    const old = conns.get(entranceId);
    if (old) old.ws.close(4408, "duplicate connection");

    const now = Date.now();
    const meta = metaOf(req);
    const conn: Conn = {
      ws,
      entranceId,
      memberId,
      spaceId,
      alive: true,
      connectedAt: now,
      // 重连（旧连接尚在，被本次踢掉）沿用旧上线时刻：通道没有真正"下线又上线"
      onlineSince: old?.onlineSince ?? now,
      meta,
      timedOut: false,
    };
    conns.set(entranceId, conn);
    // WS 连接 = 在线：刷新 last_seen（App 判定对方在线）
    getDb().prepare(`UPDATE entrances SET last_seen = ? WHERE entrance_id = ?`).run(now, entranceId);
    logConnection({ entranceId, spaceId, event: "connect", atMs: now, meta });
    broadcastPeerStatus(entranceId, "peer.online");
    console.log(`[req] WS /ws connect entrance=${entranceId} space=${spaceId} total=${conns.size}`);

    ws.send(JSON.stringify({ id: 1, type: "hello", payload: { entrance_id: entranceId, space_id: spaceId } }));

    ws.on("message", (data) => {
      try {
        const frame = JSON.parse(data.toString());
        if (frame.type === "ping") {
          ws.send(JSON.stringify({ id: frame.id ?? 0, type: "pong", payload: {} }));
        }
      } catch {
        // 忽略非法帧
      }
    });

    ws.on("pong", () => {
      conn.alive = true;
    });

    ws.on("close", (code, reason) => {
      const atMs = Date.now();
      // 先广播离线（peer 广播按发起方空间分组，此时 conn 还在 conns）再删除
      broadcastPeerStatus(entranceId, "peer.offline");
      if (conns.get(entranceId) === conn) conns.delete(entranceId);
      // WS 断开 = 离线：last_seen 置 0（App 判定离线）
      getDb().prepare(`UPDATE entrances SET last_seen = 0 WHERE entrance_id = ?`).run(entranceId);
      logConnection({
        entranceId,
        spaceId,
        event: conn.timedOut ? "heartbeat_timeout" : "disconnect",
        atMs,
        durationMs: atMs - conn.connectedAt,
        closeCode: typeof code === "number" ? code : null,
        closeReason: reason?.toString("utf8") ?? null,
        meta: conn.meta,
      });
      console.log(`[req] WS /ws disconnect entrance=${entranceId} total=${conns.size}`);
    });
  });

  // 心跳：每 30s 检测，不活则断开
  const heartbeat = setInterval(() => {
    for (const [entranceId, conn] of conns) {
      if (!conn.alive) {
        // 心跳超时：先打标（随后的 close 事件据此记 heartbeat_timeout，并带上
        // 来源 IP/UA），再 terminate——审计需要区分"客户端主动断"与"超时失联"。
        //
        // 注意：这里**先**从 conns 移除，所以 close 里的 broadcastPeerStatus 会
        // 因广播取不到发起方空间而静默不发——即 peer.offline 不广播。这是
        // 现状行为（对端靠 30s 轮询 + connected_at/last_seen 兜底，最多晚 30s
        // 看到离线），不是 bug，别"顺手"改成先广播再删（会让在线状态抖动）。
        conn.timedOut = true;
        conn.ws.terminate();
        conns.delete(entranceId);
        continue;
      }
      conn.alive = false;
      conn.ws.ping();
      // 心跳存活 = 在线中：刷新 last_seen（避免运行超 60s 被 App 误判离线）
      getDb().prepare(`UPDATE entrances SET last_seen = ? WHERE entrance_id = ?`).run(Date.now(), entranceId);
    }
  }, 30_000);
  wss.on("close", () => clearInterval(heartbeat));
}

/** 向对端广播新消息（先持久化后广播，PROTOCOL.md §8.3）。
 *  Multiverse：按消息落库的 Space 分组（发信方可能无 WS 连接，故查库而非取 conn）。 */
export function broadcastNewMessage(exceptEntranceId: string, message: MessageEnvelope & { server_sequence: number; created_at: number }): void {
  const row = getDb()
    .prepare(`SELECT space_id FROM messages WHERE message_id = ?`)
    .get(message.message_id) as { space_id: string } | undefined;
  if (!row) return;
  for (const [entranceId, conn] of conns) {
    if (entranceId === exceptEntranceId) continue;
    if (conn.spaceId !== row.space_id) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(
        JSON.stringify({
          id: 0,
          type: "message.new",
          payload: { message, server_sequence: message.server_sequence },
        })
      );
    }
  }
}

/** 通道自助退役（`POST /entrances/retire`，entrances.retireEntrance）：让它立刻从在线表消失。
 *
 * **这里刻意不发 `entrance.revoked`，也不主动 close**：
 * - `entrance.revoked`（+ 4403）是客户端**自毁本地数据**的授权信号（docs/E2EE.md §9.3）。
 *   退役接口只认 session token（"注销我自己"），若由它发出这帧，偷到 session 的人就能
 *   远程擦掉这条通道——把撤销刻意筑起的口令闸门（docs/PROTOCOL.md §7.2）从旁路绕过。
 * - 任何主动关闭（含 1000）都会让客户端立刻重连，撞上 403 `ENTRANCE_REVOKED`
 *   → 同样触发自毁。所以只静默摘出 `conns`，socket 交给客户端自己退出时收尾。
 *
 * 摘出的效果：心跳不再给它刷 last_seen（ws.ts 心跳只遍历 conns），也不再收到任何广播，
 * 对端下一次 /entrances 或轮询就看不到它在线——无需等待 30s 轮询兜底。
 */
export function forgetEntranceConnection(entranceId: string): void {
  // 顺序不能反：broadcastPeerStatus 靠 conns 里的连接取空间与人身份，摘掉就广播不了
  broadcastPeerStatus(entranceId, "peer.offline");
  conns.delete(entranceId);
}

/** 通知通道被撤销（PROTOCOL.md §8.2 entrance.revoked）。
 *  发帧后主动关闭连接并移出 conns——否则被撤销通道仍能持续接收新消息广播（P2 修复）。 */
export function notifyRevoked(entranceId: string): void {
  const conn = conns.get(entranceId);
  if (!conn) return;
  if (conn.ws.readyState === WebSocket.OPEN) {
    conn.ws.send(JSON.stringify({ id: 0, type: "entrance.revoked", payload: { entrance_id: entranceId } }));
    conn.ws.close(4403, "REVOKED");
  }
  conns.delete(entranceId);
}
