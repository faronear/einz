/**
 * serverConfig.json 的定位与读取（全库唯一入口）。
 *
 * 为什么要单独一个模块：`serverConfig.json` 既要被 config.ts 读（产品参数，如 maxSpaces），
 * 也要被 db.ts / backup.ts 读（`dataStore` 决定 SQLite 文件在哪）。而 config.ts 本身
 * import 了 db.ts 的 getDb——若 db.ts 反过来 import config.ts 就成环。把这些「读配置文件」
 * 的逻辑抽到这里，两边都只依赖它，无环。
 *
 * 路径规则：优先环境变量 `EINZ_CONFIG`，否则 `server/config/serverConfig.json`（本机开发）。
 * Docker 部署靠 `EINZ_CONFIG=/config/serverConfig.json` 指向挂载进来的文件——两种形态
 * 都是「config/ 目录 + 同名文件」。
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));

/** serverConfig.json 的绝对路径。 */
export function configFilePath(): string {
  return process.env.EINZ_CONFIG ?? resolve(HERE, "../config/serverConfig.json");
}

/** serverConfig.json 的原始字段（camelCase，与对外 ServerConfig 的 snake_case 刻意区分）。 */
export interface FileConfig {
  maxSpaces?: number;
  maxEntrancesPerSpace?: number;
  maxMembersPerSpace?: number;
  minAppVersion?: string;
  appDownloadUrl?: string;
  recommendAppVersion?: string;
  /** SQLite 数据文件的路径：绝对路径，或**相对 serverConfig.json 所在目录**的相对路径
   *  （如 `"../data/einz.nosf.sqlite.db"`）。空/未设 → 退回内置默认。
   *
   *  为什么不直接改默认文件名：`.nosf.` 是**本机 Seafile 忽略约定**（个人 sysconfig），
   *  不该把产品默认名绑死在这上面——放配置里，谁需要谁设。相对路径以配置文件目录为基准，
   *  同一串在本机（server/config → server/data）与容器（/config → /data）都成立。
   *  优先级见 db.ts 的 openDb（EINZ_DB 覆盖它）。 */
  dataStore?: string;
}

let fileConfigCache: FileConfig | null = null;

/** 读取并缓存 serverConfig.json（每次进程读一次；文件缺失或解析失败按空配置继续）。
 *  缓存是进程级的：测试若要在同一进程里改配置，必须在**首次读取前**设好 `EINZ_CONFIG`。 */
export function readFileConfig(): FileConfig {
  if (fileConfigCache != null) return fileConfigCache;
  const path = configFilePath();
  if (existsSync(path)) {
    try {
      fileConfigCache = JSON.parse(readFileSync(path, "utf8")) as FileConfig;
    } catch (e) {
      console.warn(`[einz] serverConfig.json 解析失败（按默认配置继续）: ${e}`);
      fileConfigCache = {};
    }
  } else {
    fileConfigCache = {};
  }
  return fileConfigCache;
}

/** 纯函数：把 `dataStore` 的值解析成绝对路径。
 *  空串 / 纯空白 / 非字符串 → undefined（调用方退回自己的默认值）；
 *  相对路径以 `configPath` 所在目录为基准（**不是 cwd**）。
 *  独立成纯函数只为可测——文件读取与缓存不进这里。 */
export function resolveDataStoreValue(raw: unknown, configPath: string): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (trimmed.length === 0) return undefined;
  return isAbsolute(trimmed) ? trimmed : resolve(dirname(configPath), trimmed);
}

/** 解析配置文件里 `dataStore` 指向的数据库文件（绝对路径）；没配就是 undefined。 */
export function resolveDataStorePath(): string | undefined {
  return resolveDataStoreValue(readFileConfig().dataStore, configFilePath());
}
