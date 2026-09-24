import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getDb } from "./db.js";

const HERE = resolve(import.meta.dirname ?? process.cwd());

export interface EntranceConfig {
  entrance_id: string;
  member_id: string;
  public_key: string; // base64(X25519 公钥)
  status: "active" | "revoked";
}

export interface ServerConfig {
  /** Multiverse：协议版本（v2-multiverse，见 PROTOCOL_MULTIVERSE.md） */
  protocol_version: string;
  /** Multiverse：能力清单（随端点实现逐步扩展） */
  capabilities: string[];
  /** 空间数量上限（serverConfig.json 的 maxSpaces：0=不限；1=单空间即退回 v1 模式；n=最多 n 个）。 */
  max_spaces: number;
  /** 单空间的通道（登记项）数量上限（serverConfig.json 的 maxEntrancesPerSpace：
   *  0=不限；n=该空间最多 n 条通道）。**防滥用**（老板 2026-09-23）：不限通道数是
   *  产品的本意（同身份多通道），但一个空间被灌进成百上千条通道会白吃存储与推送
   *  资源——用它做总闸。计数含已撤销（revoked）的通道：**销毁不退还额度**，否则
   *  "反复开通/销毁"可无限刷（老板 2026-09-23 定）。 */
  max_entrances_per_space: number;
}

/** 读取 serverConfig.json（默认 server/config/serverConfig.json——本机配置
 *  不入 git；可用环境变量 `EINZ_CONFIG` 指向别处，Docker 部署靠它读挂载进来的
 *  /config/serverConfig.json，两种形态都是"config/ 目录 + 同名文件"）。
 *  服务端每次启动读取一次（改配置需重启生效；文件缺失或解析失败按默认值处理）。
 *  当前支持字段：maxSpaces、maxEntrancesPerSpace。 */
let fileConfigCache: { maxSpaces?: number; maxEntrancesPerSpace?: number } | null = null;
function readFileConfig(): { maxSpaces?: number; maxEntrancesPerSpace?: number } {
  if (fileConfigCache != null) return fileConfigCache;
  const path = process.env.EINZ_CONFIG ?? resolve(HERE, "../config/serverConfig.json");
  if (existsSync(path)) {
    try {
      fileConfigCache = JSON.parse(readFileSync(path, "utf8")) as {
        maxSpaces?: number;
        maxEntrancesPerSpace?: number;
      };
    } catch (e) {
      console.warn(`[einz] serverConfig.json 解析失败（按默认配置继续）: ${e}`);
      fileConfigCache = {};
    }
  } else {
    fileConfigCache = {};
  }
  return fileConfigCache;
}

/** 加载服务配置：v2 Multiverse 下空间由客户端 POST /spaces 创建——服务端不再
 *  持有/生成全局 space_id（老板 2026-09-10）；白名单靠动态登记；maxSpaces
 *  来自 config.json（每次启动读取）。 */
export function loadConfig(): ServerConfig {
  const fc = readFileConfig();
  const maxSpaces =
    typeof fc.maxSpaces === "number" && fc.maxSpaces >= 0 ? Math.floor(fc.maxSpaces) : 0;
  const maxEntrancesPerSpace =
    typeof fc.maxEntrancesPerSpace === "number" && fc.maxEntrancesPerSpace >= 0
      ? Math.floor(fc.maxEntrancesPerSpace)
      : 0;
  return {
    protocol_version: "v2-multiverse",
    capabilities: ["spaces", "join-tokens"],
    max_spaces: maxSpaces,
    max_entrances_per_space: maxEntrancesPerSpace,
  };
}

/** 通道在库里的三种状态。**revoked 与 missing 是不同产品语义，禁止再合并成一个布尔**：
 * 前者是"这条通道被明确撤销"（可能涉嫌被盗用 → 客户端自毁本地数据），后者是
 * "此通道不在册"（库被清/从未登记 → 客户端只应离线警告，绝不销毁数据）。 */
export type EntranceStatus = "active" | "revoked" | "missing";

/**
 * 通道状态（判定源 = 数据库 entrances 表）。撤销（status='revoked'）实时生效（E2EE.md §9.3）。
 *
 * 注：v1 时代白名单来自 config.json 的静态数组，Multiverse 改成动态登记后
 * 配置参数已无用——2026-09-15 收敛时去掉（评审架构项 #2）。
 */
export function getEntranceStatus(entranceId: string): EntranceStatus {
  const row = getDb()
    .prepare(`SELECT status FROM entrances WHERE entrance_id = ?`)
    .get(entranceId) as { status: string } | undefined;
  if (row == null) return "missing"; // db 无记录 = 未登记（含库被重置）
  return row.status === "revoked" ? "revoked" : "active";
}

/** 取通道信息（含公钥，用于 challenge seal 等）。判定源 = 数据库 entrances 表。 */
export function getEntrance(entranceId: string): EntranceConfig | undefined {
  const row = getDb()
    .prepare(`SELECT entrance_id, member_id, public_key, status FROM entrances WHERE entrance_id = ?`)
    .get(entranceId) as { entrance_id: string; member_id: string; public_key: string; status: string } | undefined;
  if (!row) return undefined;
  return {
    entrance_id: row.entrance_id,
    member_id: row.member_id,
    public_key: row.public_key,
    status: row.status as EntranceConfig["status"],
  };
}
