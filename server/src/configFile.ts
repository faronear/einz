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
import { watch, type FSWatcher } from "chokidar";

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
  coldAppVersion?: string;
  appDownloadUrl?: string;
  hotAppVersion?: string;
  /** SQLite 数据文件的路径：绝对路径，或**相对 serverConfig.json 所在目录**的相对路径
   *  （如 `"../data/einz.nosf.sqlite.db"`）。空/未设 → 退回内置默认。
   *
   *  为什么不直接改默认文件名：`.nosf.` 是**本机 Seafile 忽略约定**（个人 sysconfig），
   *  不该把产品默认名绑死在这上面——放配置里，谁需要谁设。相对路径以配置文件目录为基准，
   *  同一串在本机（server/config → server/data）与容器（/config → /data）都成立。
   *  优先级见 db.ts 的 openDb（EINZ_DB 覆盖它）。 */
  dataStore?: string;
}

/** 缓存 = "最后一次读成功的配置"（2026-10-10 起可热更新）：
 * - **首次**读取（无缓存）：文件缺失/解析失败 → 空配置 `{}`（冷启动没有"旧值"可保留）；
 * - **热加载**（已有缓存）：文件缺失/解析失败 → **保留旧值**——运维手滑写坏 JSON
 *   不该把线上配置清成默认值（例如把 coldAppVersion 清空 = 强制升级闸失效）。 */
let fileConfigCache: FileConfig | null = null;

/** 从磁盘读一次 serverConfig.json（不缓存、不抛错）。
 *  返回 null = 本次读失败（缺失/解析失败）；[isHot] 决定是否保留旧值。 */
function readConfigFromDisk(path: string, isHot: boolean): FileConfig | null {
  if (!existsSync(path)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      console.warn(`[einz] serverConfig.json 不是 JSON 对象（保留${isHot ? "旧配置" : "默认配置"}）`);
      return null;
    }
    return parsed as FileConfig;
  } catch (e) {
    console.warn(`[einz] serverConfig.json 解析失败（保留${isHot ? "旧配置" : "默认配置"}）: ${e}`);
    return null;
  }
}

/** 读取 serverConfig.json（带缓存；热加载由 [startConfigWatcher] 驱动）。
 *  测试若要在同一进程里改配置，必须在**首次读取前**设好 `EINZ_CONFIG`。 */
export function readFileConfig(): FileConfig {
  if (fileConfigCache != null) return fileConfigCache;
  fileConfigCache = readConfigFromDisk(configFilePath(), false) ?? {};
  return fileConfigCache;
}

/** 让下一次 [readFileConfig] 重读磁盘（只失效缓存，不立刻读——调用方随后会读）。 */
export function invalidateConfigCache(): void {
  fileConfigCache = null;
}

/** 后台监听 serverConfig.json，变更时自动失效缓存 → **改配置不用重启**（2026-10-10）。
 *
 *  参考 pex 项目的 envar-tool.js（chokidar watch + 变更时重读）；einz 侧的差异：
 *  ① 失效缓存而非合并进长命对象（einz 的 FileConfig 是扁平的，消费方每次
 *     loadConfig() 都会重新归一化）；② 读失败保留旧值（见 [fileConfigCache] 注释）。
 *
 *  生效范围：所有"每次请求 loadConfig()"的字段（maxSpaces / 通道成员上限 /
 *  coldAppVersion / hotAppVersion / appDownloadUrl，/health 实时下发）；
 *  **dataStore（SQLite 路径）除外**——它只在启动 openDb() 时消费，改了要重启。
 *
 *  只在 server 入口（app.ts）启动一次；测试进程**不调**本函数（避免测试里
 *  挂出关不掉的 watcher、且测试配置本来就是进程级固定的）。
 *  文件缺失时照常监听（chokidar 对不存在的路径会等它出现）——运维临时删掉
 *  配置文件 → 保留旧值；重新写好后自动生效。 */
export function startConfigWatcher(): FSWatcher {
  const path = configFilePath();
  return watch(path, {
    // 只认 change：新建/删除/重命名由 change 覆盖不了的语义在热加载里都不成立
    // （"删文件 = 用默认配置"太危险，故读失败一律保留旧值）；
    // awaitWriteFinish 防"编辑器先写一半再落盘"触发两次解析失败
    // （einz 的保留旧值策略下只是多一次 warn，但能避免无谓日志）。
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 },
  }).on("change", () => {
    const fresh = readConfigFromDisk(path, true);
    if (fresh === null) return; // 保留旧值（fileConfigCache 不动）
    fileConfigCache = fresh;
    console.log(`[einz] serverConfig.json 已热加载（${path}）`);
  });
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
