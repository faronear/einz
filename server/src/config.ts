import { randomUUID } from "node:crypto";
import { getDb, getMeta, setMeta } from "./db.js";

export interface DeviceConfig {
  device_id: string;
  person_id: string;
  public_key: string; // base64(X25519 公钥)
  status: "active" | "revoked";
}

export interface ServerConfig {
  space_id: string;
}

/** 加载服务配置：space_id 持久化在 db meta 表（首启自动生成 UUID，之后不变）。
 *  不再读取 config.json——自主模式：白名单完全靠动态登记
 *  （POST /devices/enroll：第一个设备免邀请码自举为创建者，之后设备凭邀请码加入）。 */
export function loadConfig(): ServerConfig {
  const existing = getMeta("space_id");
  if (existing) return { space_id: existing };
  const spaceId = randomUUID();
  setMeta("space_id", spaceId);
  console.log(`[einz] 首次启动：已生成 space_id=${spaceId}（持久化在 db meta，可在 /health 查看）`);
  return { space_id: spaceId };
}

/**
 * 设备是否在白名单且未被撤销。
 * 判定源 = 数据库 devices 表（运行时可写：POST /devices/enroll 动态登记）。
 * 撤销（status='revoked'）实时生效（E2EE.md §9.3）。
 */
export function isActiveDevice(_cfg: ServerConfig, deviceId: string): boolean {
  const row = getDb()
    .prepare(`SELECT status FROM devices WHERE device_id = ?`)
    .get(deviceId) as { status: string } | undefined;
  if (row == null) return false; // db 无记录 = 未登记 → 拒绝
  return row.status === "active";
}

/** 取设备信息（含公钥，用于 challenge seal 等）。判定源 = 数据库 devices 表。 */
export function getDevice(_cfg: ServerConfig, deviceId: string): DeviceConfig | undefined {
  const row = getDb()
    .prepare(`SELECT device_id, person_id, public_key, status FROM devices WHERE device_id = ?`)
    .get(deviceId) as { device_id: string; person_id: string; public_key: string; status: string } | undefined;
  if (!row) return undefined;
  return {
    device_id: row.device_id,
    person_id: row.person_id,
    public_key: row.public_key,
    status: row.status as DeviceConfig["status"],
  };
}
