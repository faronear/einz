import { WebSocketServer, WebSocket } from "ws";
import { randomUUID } from "node:crypto";
import { resolveSession } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";
import type { MessageEnvelope } from "./messages.js";
import { getDb } from "./db.js";

interface Conn {
  ws: WebSocket;
  deviceId: string;
  spaceId: string; // Multiverse：连接绑定的 Space（legacy 回落 cfg.space_id）
  alive: boolean;
  connectedAt: number; // 本次 WS 连接建立时刻（ms）——/devices 显示"上线时间"
}

const conns = new Map<string, Conn>(); // device_id → 连接（一人一机 V1：每设备至多 1 条连接）

/** 当前在线 WS 连接数（/health 健康检查用）。 */
export function wsConnCount(): number {
  return conns.size;
}

/** 设备当前 WS 连接的建立时刻（ms；离线设备返回 null）。 */
export function getConnectedAt(deviceId: string): number | null {
  return conns.get(deviceId)?.connectedAt ?? null;
}

/** 广播只发给与发起方同一 Space 的在线设备（Multiverse：跨空间不推送；
 *  发起方不在线（无连接）时不广播）。 */
function sameSpace(exceptDeviceId: string): string | null {
  return conns.get(exceptDeviceId)?.spaceId ?? null;
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

function broadcastPeerStatus(exceptDeviceId: string, type: "peer.online" | "peer.offline"): void {
  const spaceId = sameSpace(exceptDeviceId);
  if (spaceId == null) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type, payload: { device_id: exceptDeviceId } }));
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
export function attachWs(wss: WebSocketServer, cfg: ServerConfig): void {
  wss.on("connection", (ws, req) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const pv = url.searchParams.get("pv");
    const token = url.searchParams.get("token");

    if (pv !== "1") {
      ws.close(4400, "PROTOCOL_VERSION_MISMATCH");
      return;
    }

    let deviceId: string;
    let spaceId: string;
    try {
      const sess = resolveSession(token ?? "");
      deviceId = sess.device_id;
      // Multiverse：WS 绑定 session 的 Space（legacy 无空间 → 空串）
      spaceId = sess.space_id ?? "";
    } catch {
      ws.close(4401, "UNAUTHORIZED");
      return;
    }
    if (!isActiveDevice(cfg, deviceId)) {
      ws.close(4403, "FORBIDDEN");
      return;
    }

    // V1 一人一机：重复连接踢掉旧连接
    const old = conns.get(deviceId);
    if (old) old.ws.close(4408, "duplicate connection");

    const conn: Conn = { ws, deviceId, spaceId, alive: true, connectedAt: Date.now() };
    conns.set(deviceId, conn);
    // WS 连接 = 在线：刷新 last_seen（App 判定对方在线）
    getDb().prepare(`UPDATE devices SET last_seen = ? WHERE device_id = ?`).run(Date.now(), deviceId);
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

    ws.on("close", () => {
      // 先广播离线（peer 广播按发起方空间分组，此时 conn 还在 conns）再删除
      broadcastPeerStatus(deviceId, "peer.offline");
      if (conns.get(deviceId) === conn) conns.delete(deviceId);
      // WS 断开 = 离线：last_seen 置 0（App 判定离线）
      getDb().prepare(`UPDATE devices SET last_seen = 0 WHERE device_id = ?`).run(deviceId);
      console.log(`[req] WS /ws disconnect device=${deviceId} total=${conns.size}`);
    });
  });

  // 心跳：每 30s 检测，不活则断开
  const heartbeat = setInterval(() => {
    for (const [deviceId, conn] of conns) {
      if (!conn.alive) {
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

/** 通知剩余设备执行 Space Key 轮换（PROTOCOL.md §8.2 key.rotation）。
 *  Multiverse：仅同 Space 的在线设备（发起方无 WS 连接时不广播）。 */
export function notifyKeyRotation(exceptDeviceId: string, keyVersion: number): void {
  const spaceId = sameSpace(exceptDeviceId);
  if (spaceId == null) return;
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.spaceId !== spaceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type: "key.rotation", payload: { key_version: keyVersion } }));
    }
  }
}

export { randomUUID };
