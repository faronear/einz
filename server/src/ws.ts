import { WebSocketServer, WebSocket } from "ws";
import { optionalBearerToken, requireSession } from "./guard.js";
import type { MessageEnvelope } from "./messages.js";
import { getDb } from "./db.js";
import { logConnection, metaOf, type RequestMeta } from "./audit.js";

interface Conn {
  ws: WebSocket;
  deviceId: string;
  personId: string | null; // 设备归属身份（同一人的多设备共享 person_id）
  spaceId: string; // 连接绑定的 Space（会话必带 space）
  alive: boolean;
  connectedAt: number; // 本次 WS 连接建立时刻（ms）——/devices 显示"上线时间"
  meta: RequestMeta; // 来源 IP / UA（建连时的 req），审计落库用
  timedOut: boolean; // 已被心跳判定为超时（close 时据此记 heartbeat_timeout）
}

const conns = new Map<string, Conn>(); // device_id → 连接（一人一机 V1：每设备至多 1 条连接）

/** 设备当前 WS 连接的建立时刻（ms；离线设备返回 null）。 */
export function getConnectedAt(deviceId: string): number | null {
  return conns.get(deviceId)?.connectedAt ?? null;
}

/** 发起方设备所属 Space：优先其在线连接；**不在线时回退查 sessions**
 *  （同一设备可能有多条历史会话——取最新的非空 space_id）。
 *  背景：广播此前只认发起方的在线连接（sameSpace），发起方 WS 不在（移动端切
 *  后台/断线）就一条都不发 → 对端改名/换头像后 TUI 一直显示旧名
 *  （老板 2026-09-11 实测）。 */
function spaceOfDevice(deviceId: string): string | null {
  const online = conns.get(deviceId)?.spaceId;
  if (online != null && online !== "") return online;
  const row = getDb()
    .prepare(
      `SELECT space_id FROM sessions WHERE device_id = ? AND space_id IS NOT NULL ORDER BY created_at DESC LIMIT 1`
    )
    .get(deviceId) as { space_id: string } | undefined;
  return row?.space_id ?? null;
}

/** 广播只发给**另一个人**的在线设备：同一 person 的多台设备（同一人的手机+电脑）
 *  不算"对方"——此前只排除发起设备本身，自己的第二台设备一上线，第一台就把
 *  对方灯点亮（老板 2026-09-16 实测：B 从未加入却显示在线）。
 *  payload 带 person_id：客户端（可能连着旧版服务端）据此二次过滤。 */
function broadcastPeerStatus(exceptDeviceId: string, type: "peer.online" | "peer.offline"): void {
  const origin = conns.get(exceptDeviceId);
  const spaceId = origin?.spaceId ?? null;
  if (spaceId == null) return;
  const originPersonId = origin?.personId ?? null;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (originPersonId != null && conn.personId === originPersonId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(
        JSON.stringify({
          id: 0,
          type,
          payload: { device_id: exceptDeviceId, person_id: originPersonId },
        })
      );
    }
  }
}

/** 空间口令已被重设：通知其余在线设备（客户端收到后只发通知不弹窗）。 */
export function broadcastPassphraseRotated(exceptDeviceId: string): void {
  const spaceId = spaceOfDevice(exceptDeviceId);
  if (spaceId == null) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(
        JSON.stringify({ id: 0, type: "passphrase.rotated", payload: { device_id: exceptDeviceId } })
      );
    }
  }
}

/** 消息回执（已送达/已读）更新：通知同 Space 的其他设备。
 *  用 spaceOfDevice（带 sessions 兜底）——上报设备可能没有活跃 WS 连接
 *  （移动端切后台后仍在同步）。 */
export function broadcastReceiptUpdated(
  exceptDeviceId: string,
  payload: { person_id: string; delivered_upto_seq: number; read_upto_seq: number }
): void {
  const spaceId = spaceOfDevice(exceptDeviceId);
  if (spaceId == null) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type: "receipt.updated", payload }));
    }
  }
}

/** 改名/改设备名：通知其余在线设备立即更新对方名称（App/TUI 顶部条）。 */
export function broadcastProfileUpdated(
  exceptDeviceId: string,
  payload: { person_id?: string; device_id: string; person_name?: string; device_name?: string }
): void {
  const spaceId = spaceOfDevice(exceptDeviceId);
  if (spaceId == null) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
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

    if (pv !== "1") {
      ws.close(4400, "PROTOCOL_VERSION_MISMATCH");
      return;
    }

    let deviceId: string;
    let spaceId: string;
    let personId: string | null;
    try {
      // requireSession 同时完成：会话有效 + 设备在册 + 会话带 space（v1 收敛后必备）
      const sess = requireSession(token);
      deviceId = sess.device_id;
      spaceId = sess.space_id;
      // 设备归属身份：peer 广播据此跳过同一人的其它设备（同人≠对方）
      personId = sess.person_id === "" ? null : sess.person_id;
    } catch {
      ws.close(4401, "UNAUTHORIZED");
      return;
    }
    // V1 一人一机：重复连接踢掉旧连接
    const old = conns.get(deviceId);
    if (old) old.ws.close(4408, "duplicate connection");

    const now = Date.now();
    const meta = metaOf(req);
    const conn: Conn = {
      ws,
      deviceId,
      personId,
      spaceId,
      alive: true,
      connectedAt: now,
      meta,
      timedOut: false,
    };
    conns.set(deviceId, conn);
    // WS 连接 = 在线：刷新 last_seen（App 判定对方在线）
    getDb().prepare(`UPDATE devices SET last_seen = ? WHERE device_id = ?`).run(now, deviceId);
    logConnection({ deviceId, spaceId, event: "connect", atMs: now, meta });
    broadcastPeerStatus(deviceId, "peer.online");
    console.log(`[req] WS /ws connect device=${deviceId} space=${spaceId} total=${conns.size}`);

    ws.send(JSON.stringify({ id: 1, type: "hello", payload: { device_id: deviceId, space_id: spaceId } }));

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
      broadcastPeerStatus(deviceId, "peer.offline");
      if (conns.get(deviceId) === conn) conns.delete(deviceId);
      // WS 断开 = 离线：last_seen 置 0（App 判定离线）
      getDb().prepare(`UPDATE devices SET last_seen = 0 WHERE device_id = ?`).run(deviceId);
      logConnection({
        deviceId,
        spaceId,
        event: conn.timedOut ? "heartbeat_timeout" : "disconnect",
        atMs,
        durationMs: atMs - conn.connectedAt,
        closeCode: typeof code === "number" ? code : null,
        closeReason: reason?.toString("utf8") ?? null,
        meta: conn.meta,
      });
      console.log(`[req] WS /ws disconnect device=${deviceId} total=${conns.size}`);
    });
  });

  // 心跳：每 30s 检测，不活则断开
  const heartbeat = setInterval(() => {
    for (const [deviceId, conn] of conns) {
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
        conns.delete(deviceId);
        continue;
      }
      conn.alive = false;
      conn.ws.ping();
      // 心跳存活 = 在线中：刷新 last_seen（避免运行超 60s 被 App 误判离线）
      getDb().prepare(`UPDATE devices SET last_seen = ? WHERE device_id = ?`).run(Date.now(), deviceId);
    }
  }, 30_000);
  wss.on("close", () => clearInterval(heartbeat));
}

/** 向对端广播新消息（先持久化后广播，PROTOCOL.md §8.3）。
 *  Multiverse：按消息落库的 Space 分组（发信方可能无 WS 连接，故查库而非取 conn）。 */
export function broadcastNewMessage(exceptDeviceId: string, message: MessageEnvelope & { server_sequence: number; created_at: number }): void {
  const row = getDb()
    .prepare(`SELECT space_id FROM messages WHERE message_id = ?`)
    .get(message.message_id) as { space_id: string } | undefined;
  if (!row) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
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

/** 通知设备被撤销（PROTOCOL.md §8.2 device.revoked）。
 *  发帧后主动关闭连接并移出 conns——否则被撤销设备仍能持续接收新消息广播（P2 修复）。 */
export function notifyRevoked(deviceId: string): void {
  const conn = conns.get(deviceId);
  if (!conn) return;
  if (conn.ws.readyState === WebSocket.OPEN) {
    conn.ws.send(JSON.stringify({ id: 0, type: "device.revoked", payload: { device_id: deviceId } }));
    conn.ws.close(4403, "REVOKED");
  }
  conns.delete(deviceId);
}
