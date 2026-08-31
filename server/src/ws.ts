import { WebSocketServer, WebSocket } from "ws";
import { randomUUID } from "node:crypto";
import { resolveSession } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";
import type { MessageEnvelope } from "./messages.js";

interface Conn {
  ws: WebSocket;
  deviceId: string;
  alive: boolean;
}

const conns = new Map<string, Conn>(); // device_id → 连接（一人一机 V1：每设备至多 1 条连接）

/** 当前在线 WS 连接数（/health 健康检查用）。 */
export function wsConnCount(): number {
  return conns.size;
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
    try {
      deviceId = resolveSession(token ?? "").device_id;
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

    const conn: Conn = { ws, deviceId, alive: true };
    conns.set(deviceId, conn);
    console.log(`[req] WS /ws connect device=${deviceId} total=${conns.size}`);

    ws.send(JSON.stringify({ id: 1, type: "hello", payload: { device_id: deviceId, space_id: cfg.space_id } }));

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
      if (conns.get(deviceId) === conn) conns.delete(deviceId);
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
    }
  }, 30_000);
  wss.on("close", () => clearInterval(heartbeat));
}

/** 向对端广播新消息（先持久化后广播，PROTOCOL.md §8.3）。 */
export function broadcastNewMessage(exceptDeviceId: string, message: MessageEnvelope & { server_sequence: number; created_at: number }): void {
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
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

/** 通知剩余设备执行 Space Key 轮换（PROTOCOL.md §8.2 key.rotation）。 */
export function notifyKeyRotation(exceptDeviceId: string, keyVersion: number): void {
  for (const [deviceId, conn] of conns) {
    if (deviceId === exceptDeviceId) continue;
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify({ id: 0, type: "key.rotation", payload: { key_version: keyVersion } }));
    }
  }
}

export { randomUUID };
