import { getDb } from "./db.js";
import { ApiError, resolveSession, touchLastSeen } from "./auth.js";
import { isActiveDevice, type ServerConfig } from "./config.js";

export interface PushTokenBody {
  platform: "ios" | "android";
  token: string;
}

/** POST /push/register：注册/更新 Push Token（PROTOCOL.md §7.3）。 */
export function registerPushToken(cfg: ServerConfig, token: string, body: unknown): { ok: true } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);

  const b = body as Partial<PushTokenBody>;
  if ((b.platform !== "ios" && b.platform !== "android") || typeof b.token !== "string" || b.token.length === 0) {
    throw new ApiError("INVALID_REQUEST", "invalid push token body", 400);
  }

  getDb()
    .prepare(
      `INSERT INTO push_tokens (device_id, platform, token, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET platform = excluded.platform, token = excluded.token, updated_at = excluded.updated_at`
    )
    .run(device_id, b.platform, b.token, Date.now());
  return { ok: true };
}

/** DELETE /push/register：注销 Push Token。 */
export function unregisterPushToken(cfg: ServerConfig, token: string): { ok: true } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  getDb().prepare(`DELETE FROM push_tokens WHERE device_id = ?`).run(device_id);
  return { ok: true };
}

/**
 * 推送通知（PROTOCOL.md §7.3 / productLens §10）：
 * V1 只发"有新消息"提示，绝不携带正文。APNs/FCM 实际下发在 Phase 3 接入；
 * 当前实现为占位：从 push_tokens 取目标设备，记录日志（不泄露内容）。
 */
export function sendPushHint(spaceId: string, exceptDeviceId: string): void {
  const rows = getDb()
    .prepare(`SELECT device_id, platform, token FROM push_tokens WHERE device_id != ?`)
    .all(exceptDeviceId) as { device_id: string; platform: string; token: string }[];

  for (const row of rows) {
    // Phase 3: 调用 APNs / FCM 发送 { type: "new_message", space_id }，无正文。
    console.log(`[push-hint] device=${row.device_id} platform=${row.platform} type=new_message space=${spaceId}`);
  }
}

/** GET /space：空间信息（space_id + 成员设备 + person 名称/性别表）。 */
export function getSpace(
  cfg: ServerConfig,
  token: string
): { space_id: string; devices: unknown[]; person_names: Record<string, string>; person_genders: Record<string, string> } {
  const { device_id } = resolveSession(token);
  if (!isActiveDevice(cfg, device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  const devices = getDb()
    .prepare(`SELECT device_id, person_id, status, last_seen FROM devices WHERE status = 'active'`)
    .all();
  // person 名称表：meta person_name:personA → person_name（创建者/邀请时设置，显示层用）
  const personNames: Record<string, string> = {};
  for (const r of getDb()
    .prepare(`SELECT key, value FROM meta WHERE key LIKE 'person_name:%'`)
    .all() as { key: string; value: string }[]) {
    personNames[r.key.slice("person_name:".length)] = r.value;
  }
  // person 性别表（meta person_gender:*，male/female）：随名称表一并下发
  const personGenders: Record<string, string> = {};
  for (const r of getDb()
    .prepare(`SELECT key, value FROM meta WHERE key LIKE 'person_gender:%'`)
    .all() as { key: string; value: string }[]) {
    personGenders[r.key.slice("person_gender:".length)] = r.value;
  }
  return { space_id: "", devices, person_names: personNames, person_genders: personGenders };
}
