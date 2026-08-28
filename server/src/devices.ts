import { getDb } from "./db.js";
import { ApiError, resolveSession, touchLastSeen } from "./auth.js";
import { isActiveDevice, getDevice, type ServerConfig } from "./config.js";

/** GET /devices：设备列表（含 person 映射）。 */
export function listDevices(cfg: ServerConfig, token: string): { devices: unknown[] } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  touchLastSeen(device_id);

  const rows = getDb()
    .prepare(`SELECT device_id, person_id, status, last_seen FROM devices ORDER BY created_at`)
    .all();
  return { devices: rows };
}

/** DELETE /devices/:id：撤销设备（白名单移除 + 清 Push Token + 触发密钥轮换，PROTOCOL.md §7.2）。 */
export function revokeDevice(cfg: ServerConfig, token: string, targetDeviceId: string): { key_rotation_required: boolean } {
  const { device_id: callerId } = resolveSession(token);
  if (!isActiveDevice(cfg, callerId)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);

  const target = getDevice(cfg, targetDeviceId);
  if (!target) throw new ApiError("NOT_FOUND", "device not found", 404);
  if (target.device_id === callerId) throw new ApiError("INVALID_REQUEST", "cannot revoke self", 400);

  const db = getDb();
  const now = Date.now();
  db.prepare(`UPDATE devices SET status = 'revoked', last_seen = ? WHERE device_id = ?`).run(now, targetDeviceId);
  db.prepare(`DELETE FROM push_tokens WHERE device_id = ?`).run(targetDeviceId);
  db.prepare(`DELETE FROM sessions WHERE device_id = ?`).run(targetDeviceId);

  return { key_rotation_required: true };
}
