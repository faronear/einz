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

/**
 * POST /devices/enroll：新设备凭一次性邀请码动态登记（免认证——邀请码即准入令牌）。
 * 登记写入 devices 表（status='active'），判定源已是数据库，故登记后**立即生效、无需重启**。
 * - person_id 取自邀请码记录（不信任客户端提交），防止邀请码被用于登记成其他 person；
 * - 邀请码必须 pending 且未过期；成功后标记 used（一次性）；
 * - 已登记设备幂等返回成功；被撤销设备拒绝复活。
 */
export function enrollDevice(
  cfg: ServerConfig,
  body: unknown
): { ok: true; device_id: string; person_id: string; space_id: string } {
  const b = (body ?? {}) as { device_id?: string; public_key?: string; invite_code?: string };
  const deviceId = (b.device_id ?? "").trim();
  const publicKey = (b.public_key ?? "").trim();
  const inviteCode = (b.invite_code ?? "").trim();
  if (!deviceId || !publicKey || !inviteCode) {
    throw new ApiError("INVALID_REQUEST", "device_id / public_key / invite_code 必填", 400);
  }

  const db = getDb();
  const now = Date.now();

  // 1) 校验邀请码：存在 + pending + 未过期
  const invite = db.prepare(`SELECT person_id, status, expires_at FROM invites WHERE invite_code = ?`).get(inviteCode) as
    | { person_id: string; status: string; expires_at: number }
    | undefined;
  if (!invite) throw new ApiError("INVALID_INVITE", "邀请码不存在", 400);
  if (invite.status !== "pending") throw new ApiError("INVALID_INVITE", "邀请码已使用", 400);
  if (invite.expires_at < now) {
    db.prepare(`UPDATE invites SET status = 'expired' WHERE invite_code = ?`).run(inviteCode);
    throw new ApiError("INVALID_INVITE", "邀请码已过期，请联系创建者重新生成", 400);
  }

  // 2) 登记设备（幂等：已 active 直接成功；revoked 拒绝复活）
  const existing = db.prepare(`SELECT status FROM devices WHERE device_id = ?`).get(deviceId) as
    | { status: string }
    | undefined;
  if (existing && existing.status === "revoked") {
    throw new ApiError("FORBIDDEN", "device revoked, cannot re-enroll", 403);
  }
  if (!existing) {
    db.prepare(`INSERT INTO devices (device_id, person_id, public_key, status, created_at) VALUES (?, ?, ?, 'active', ?)`)
      .run(deviceId, invite.person_id, publicKey, now);
  }

  // 3) 标记邀请码已用（一次性）
  db.prepare(`UPDATE invites SET status = 'used', used_by = ?, used_at = ? WHERE invite_code = ?`)
    .run(deviceId, now, inviteCode);

  return { ok: true, device_id: deviceId, person_id: invite.person_id, space_id: cfg.space_id };
}
