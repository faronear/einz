import { getDb } from "./db.js";
import { readFileConfig } from "./configFile.js";

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
  /** 单空间成员（身份）数量上限（serverConfig.json 的 maxMembersPerSpace：
   *  0=不限；n=最多 n 个身份）。群聊一期（2026-10-03）：duo 空间上限恒为 2
   *  （第三个身份 join 时触发自动升格 group），group 空间用本值；建议默认 4。
   *  与 maxEntrancesPerSpace 互补：那道闸管"通道总量"（含已撤销、防刷），这道闸
   *  管"身份总量"（同身份多通道不重复计数）。 */
  max_members_per_space: number;
  /** 当前可用的最低 App 版本（serverConfig.json 的 minAppVersion）——低于它 = 已不可用。
   *  **版本三态语义（2026-10-10 老板定）**：hot_app_version = 当前正热用的版本；
   *  本值 = 当前可用的最低版本；介于两者之间 = **正在冷却**（仍可用，客户端启动弹
   *  可关闭的升级提醒），低于本值 = 不可用（弹**不可关闭**的升级窗口）。
   *  **格式 yymm.ddhh.mm**（见 scripts/appVersion.js，UTC）——与 App 自身的
   *  CFBundleShortVersionString / versionName 是同一个串，客户端可直接比大小。
   *  null = 不设下限（默认）。
   *  为什么不用 protocol_version 代替：那是 wire 兼容闸（服务端会硬拒），
   *  这个是**产品级**闸——比如某个版本有安全缺陷、或协议还能用但功能已不可靠，
   *  运维改配置即可把旧客户端挡在门外，不必动代码。 */
  min_app_version: string | null;
  /** 当前正热用的 App 版本（serverConfig.json 的 hotAppVersion）——低于它但
   *  ≥ min_app_version = **正在冷却**（2026-10-10 老板定：hot / cooling / 不可用
   *  三态，见 min_app_version 注释）。冷却中的客户端启动弹**可关闭**的升级提醒
   *  ——"有新版本了"，不拦人。null = 不设热版本（默认，不下发冷却提醒）。
   *  格式同 min_app_version（yymm.ddhh.mm）。 */
  hot_app_version: string | null;
  /** 升级入口 URL（serverConfig.json 的 appDownloadUrl）：下发到客户端，
   *  供强制升级窗口里的「下载新版本」按钮使用。null = 不给链接（客户端只显示版本信息）。 */
  app_download_url: string | null;
}

/** 加载服务配置：v2 Multiverse 下空间由客户端 POST /spaces 创建——服务端不再
 *  持有/生成全局 space_id（老板 2026-09-10）；白名单靠动态登记；maxSpaces
 *  来自 config.json（每次启动读取）。
 *
 *  注意：配置文件里的 `dataStore`（SQLite 路径）**刻意不在这里**——它属于服务端内部
 *  事实，不该随 /health 下发（ServerConfig 是给客户端看的）。它的读取见 configFile.ts，
 *  消费方是 db.ts / backup.ts。 */
export function loadConfig(): ServerConfig {
  const fc = readFileConfig();
  const maxSpaces =
    typeof fc.maxSpaces === "number" && fc.maxSpaces >= 0 ? Math.floor(fc.maxSpaces) : 0;
  const maxEntrancesPerSpace =
    typeof fc.maxEntrancesPerSpace === "number" && fc.maxEntrancesPerSpace >= 0
      ? Math.floor(fc.maxEntrancesPerSpace)
      : 0;
  const maxMembersPerSpace =
    typeof fc.maxMembersPerSpace === "number" && fc.maxMembersPerSpace >= 0
      ? Math.floor(fc.maxMembersPerSpace)
      : 0;
  // 版本号两条都按"非空字符串才算设了"处理：空串/非字符串一律当没配（别把
  // 手滑写空当成"要求所有客户端升级"）
  const minAppVersion =
    typeof fc.minAppVersion === "string" && fc.minAppVersion.trim().length > 0
      ? fc.minAppVersion.trim()
      : null;
  // 热版本（hotAppVersion）同款归一化：空串/非字符串一律当没配
  const hotAppVersion =
    typeof fc.hotAppVersion === "string" && fc.hotAppVersion.trim().length > 0
      ? fc.hotAppVersion.trim()
      : null;
  const appDownloadUrl =
    typeof fc.appDownloadUrl === "string" && fc.appDownloadUrl.trim().length > 0
      ? fc.appDownloadUrl.trim()
      : null;
  return {
    protocol_version: "v2-multiverse",
    capabilities: ["spaces", "join-tokens"],
    max_spaces: maxSpaces,
    max_entrances_per_space: maxEntrancesPerSpace,
    max_members_per_space: maxMembersPerSpace,
    min_app_version: minAppVersion,
    hot_app_version: hotAppVersion,
    app_download_url: appDownloadUrl,
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
