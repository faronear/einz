import { readFileSync } from "node:fs";
import { resolve } from "node:path";

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
  return cfg.devices.some((d) => d.device_id === deviceId && d.status === "active");
}

export function getDevice(cfg: ServerConfig, deviceId: string): DeviceConfig | undefined {
  return cfg.devices.find((d) => d.device_id === deviceId);
}
