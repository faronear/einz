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
  // **只投给同一 Space 的其他设备**：devices 表没有 space_id，设备经
  // person_id → space_members 归属 Space。此前只按 `device_id != 自己` 过滤 →
  // 会把提示推给这台服务器上**所有空间**的设备（跨空间泄露"谁在发消息"）。
  // 同时跳过已撤销的设备（status != 'active'）。
  const rows = getDb()
    .prepare(
      `SELECT p.device_id, p.platform, p.token
         FROM push_tokens p
         JOIN devices d  ON d.device_id = p.device_id
         JOIN space_members sm ON sm.person_id = d.person_id AND sm.space_id = ?
        WHERE p.device_id != ?
          AND d.status = 'active'`,
    )
    .all(spaceId, exceptDeviceId) as { device_id: string; platform: string; token: string }[];

  for (const row of rows) {
    // Phase 3: 调用 APNs / FCM 发送 { type: "new_message", space_id }，无正文。
    console.log(`[push-hint] device=${row.device_id} platform=${row.platform} type=new_message space=${spaceId}`);
  }
}

/** GET /space：空间信息（space_id + 成员设备 + person 名称/性别表）。
 *  v2：名称/性别从 space_members 表读（display_name/gender——create/join 写入），
 *  不再读 v1 的 meta person_name:* 与 person_gender:* 键（v2 不写 meta——老板 2026-09-10
 *  反馈：标题栏对方名字一直 '-'、气泡全青色）。 */
export function getSpace(
  cfg: ServerConfig,
  token: string
): { space_id: string; devices: unknown[]; person_names: Record<string, string>; person_genders: Record<string, string> } {
  const sess = resolveSession(token);
  if (!isActiveDevice(cfg, sess.device_id)) throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  const devices = getDb()
    .prepare(`SELECT device_id, person_id, status, last_seen FROM devices WHERE status = 'active'`)
    .all();
  // v2：成员名称/性别表（space_members——按 person_id；同一身份多设备共享）
  const personNames: Record<string, string> = {};
  const personGenders: Record<string, string> = {};
  const members = getDb()
    .prepare(`SELECT person_id, display_name, gender FROM space_members WHERE space_id = ? AND person_id IS NOT NULL`)
    .all(sess.space_id) as { person_id: string; display_name: string | null; gender: string | null }[];
  for (const m of members) {
    if (m.display_name != null) personNames[m.person_id] = m.display_name;
    if (m.gender != null) personGenders[m.person_id] = m.gender;
  }
  return { space_id: sess.space_id ?? "", devices, person_names: personNames, person_genders: personGenders };
}
