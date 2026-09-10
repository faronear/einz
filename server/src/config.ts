import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getDb, getMeta, setMeta } from "./db.js";

const HERE = resolve(import.meta.dirname ?? process.cwd());

export interface DeviceConfig {
  device_id: string;
  person_id: string;
  public_key: string; // base64(X25519 公钥)
  status: "active" | "revoked";
}

export interface ServerConfig {
  space_id: string;
  /** Multiverse：协议版本（v1-single-space 迁移期保留 space_id 兼容，见 PROTOCOL_MULTIVERSE.md） */
  protocol_version: string;
  /** Multiverse：能力清单（随端点实现逐步扩展） */
  capabilities: string[];
  /** 空间数量上限（config.json 的 maxSpaces：0=不限；1=单空间即退回 v1 模式；n=最多 n 个）。 */
  max_spaces: number;
}

/** 读取 config.json（server/config.json）——服务端每次启动读取一次（改配置需
 *  重启生效；文件缺失或解析失败按默认值处理）。当前支持字段：maxSpaces。 */
let fileConfigCache: { maxSpaces?: number } | null = null;
function readFileConfig(): { maxSpaces?: number } {
  if (fileConfigCache != null) return fileConfigCache;
  const path = resolve(HERE, "../config.json");
  if (existsSync(path)) {
    try {
      fileConfigCache = JSON.parse(readFileSync(path, "utf8")) as { maxSpaces?: number };
    } catch (e) {
      console.warn(`[einz] config.json 解析失败（按默认配置继续）: ${e}`);
      fileConfigCache = {};
    }
  } else {
    fileConfigCache = {};
  }
  return fileConfigCache;
}

/** 加载服务配置：space_id 持久化在 db meta 表（首启自动生成 UUID，之后不变）。
 *  白名单完全靠动态登记（POST /devices/enroll：第一个设备免邀请码自举为创建者，
 *  之后设备凭邀请码加入）。maxSpaces 来自 config.json（每次启动读取）。 */
export function loadConfig(): ServerConfig {
  const existing = getMeta("space_id");
  const spaceId = existing ?? randomUUID();
  if (!existing) {
    setMeta("space_id", spaceId);
    console.log(`[einz] 首次启动：已生成 space_id=${spaceId}（持久化在 db meta，可在 /health 查看）`);
  }
  const fc = readFileConfig();
  const maxSpaces =
    typeof fc.maxSpaces === "number" && fc.maxSpaces >= 0 ? Math.floor(fc.maxSpaces) : 0;
  return {
    space_id: spaceId,
    protocol_version: "v2-multiverse",
    capabilities: ["spaces", "join-tokens"],
    max_spaces: maxSpaces,
  };
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
