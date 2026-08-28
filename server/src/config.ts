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

export function isActiveDevice(cfg: ServerConfig, deviceId: string): boolean {
  // 1) 必须在静态白名单（config.json）中
  const inWhitelist = cfg.devices.some((d) => d.device_id === deviceId);
  if (!inWhitelist) return false;
  // 2) 数据库撤销状态优先：devices.status = 'revoked' 即拒绝（E2EE.md §9.3）
  //    数据库无记录（首次启动/尚未登记）时回退到 config 状态，视为 active。
  const row = getDb().prepare(`SELECT status FROM devices WHERE device_id = ?`).get(deviceId) as
    | { status: string }
    | undefined;
  return row == null ? true : row.status === "active";
}

export function getDevice(cfg: ServerConfig, deviceId: string): DeviceConfig | undefined {
  return cfg.devices.find((d) => d.device_id === deviceId);
}

/**
 * 把 config.json 白名单登记进 devices 表（INSERT OR IGNORE，幂等）：
 * 使撤销（UPDATE status='revoked'）真正作用于认证/同步/发送路径（E2EE.md §9.3）。
 * 已存在的行（含被撤销状态）不受影响——撤销后重启不会"复活"。
 */
export function syncWhitelistToDb(cfg: ServerConfig): void {
  const db = getDb();
  const insert = db.prepare(
    `INSERT OR IGNORE INTO devices (device_id, person_id, public_key, status, created_at) VALUES (?, ?, ?, ?, ?)`
  );
  for (const d of cfg.devices) {
    insert.run(d.device_id, d.person_id, d.public_key, d.status, Date.now());
  }
}
