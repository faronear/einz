import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getDb } from "./db.js";

export interface DeviceConfig {
  device_id: string;
  person_id: string;
  public_key: string; // base64(X25519 公钥)
  status: "active" | "revoked";
}

export interface ServerConfig {
  space_id: string;
  devices: DeviceConfig[];
}

const DEFAULT_CONFIG_PATH = resolve(import.meta.dirname, "../config/config.json");

/** 加载静态白名单配置（productLens §8.3）。文件不存在时抛出，Server 拒绝启动。 */
export function loadConfig(path = process.env.ONLYSPACE_CONFIG ?? DEFAULT_CONFIG_PATH): ServerConfig {
  const raw = readFileSync(path, "utf8");
  const cfg = JSON.parse(raw) as ServerConfig;

  if (typeof cfg.space_id !== "string" || !Array.isArray(cfg.devices)) {
    throw new Error(`config.json 格式错误: 需要 space_id + devices`);
  }
  const active = cfg.devices.filter((d) => d.status === "active");
  if (active.length < 1) {
    throw new Error(`config.json 至少需要 1 台 active 设备`);
  }
  return cfg;
}

/**
 * 设备是否在白名单且未被撤销。
 * 判定源 = 数据库 devices 表（运行时可写：启动时 syncWhitelistToDb 登记 config.json
 * 种子，之后由动态登记端点 POST /devices/enroll 热加入）——因此新设备登记后
 * **无需重启 Server** 即生效（此前判定源是启动时载入内存的 config.json，必须重启）。
 * 撤销（status='revoked'）同样实时生效（E2EE.md §9.3）。
 */
export function isActiveDevice(_cfg: ServerConfig, deviceId: string): boolean {
  const row = getDb()
    .prepare(`SELECT status FROM devices WHERE device_id = ?`)
    .get(deviceId) as { status: string } | undefined;
  if (row == null) return false; // db 无记录 = 未登记（config.json 种子或 enroll）→ 拒绝
  return row.status === "active";
}

/**
 * 取设备信息（含公钥，用于 challenge seal 等）。
 * 优先查数据库（动态登记设备在这里；含 public_key/person_id/status），
 * 未登记时回退内存 config.json 种子——与 isActiveDevice 的判定源保持一致。
 */
export function getDevice(cfg: ServerConfig, deviceId: string): DeviceConfig | undefined {
  const row = getDb()
    .prepare(`SELECT device_id, person_id, public_key, status FROM devices WHERE device_id = ?`)
    .get(deviceId) as { device_id: string; person_id: string; public_key: string; status: string } | undefined;
  if (row) {
    return {
      device_id: row.device_id,
      person_id: row.person_id,
      public_key: row.public_key,
      status: row.status as DeviceConfig["status"],
    };
  }
  return cfg.devices.find((d) => d.device_id === deviceId);
}

/**
 * 把 config.json 白名单登记进 devices 表（UPSERT，幂等）：
 * - 新设备：INSERT；
 * - 已存在设备：仅更新 person_id / public_key（白名单改公钥后重启即生效，
 *   修复 "db 残留旧公钥 → challenge 用旧公钥 seal → 客户端解不开" 问题）；
 * - **status 不覆盖**：被撤销（status='revoked'）的设备重启后不"复活"（E2EE.md §9.3）。
 */
export function syncWhitelistToDb(cfg: ServerConfig): void {
  const db = getDb();
  const upsert = db.prepare(
    `INSERT INTO devices (device_id, person_id, public_key, status, created_at) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET person_id = excluded.person_id, public_key = excluded.public_key`
  );
  for (const d of cfg.devices) {
    upsert.run(d.device_id, d.person_id, d.public_key, d.status, Date.now());
  }
}
