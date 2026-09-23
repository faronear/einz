/**
 * Server 备份与恢复（DATABASE.md §6）
 *
 * 备份 = einz.sqlite.db（SQLite 官方 Backup API 在线备份，禁止直接复制正在写入的 db）
 *       + /data/files/（附件密文 blob）
 * 产物 = 单文件，AES-256-GCM 加密归档到 <data>/backups/。
 *
 * 注：v1 的静态白名单 config.json 已随 Multiverse 删除（设备与空间都在库里），
 *     备份里不再有该条目——`EINZ_CONFIG` 一并移除（老板 2026-09-17 确认无老备份）。
 *
 * 密钥：环境变量 EINZ_DB_BACKUP_KEY（base64 32B）。未设置时拒绝执行（防误备份明文）。
 */
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { join, resolve, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { getDb } from "./db.js";
import { assertSafeSpaceId } from "./safeId.js";

const FORMAT = "einz-server-backup-v1";

/** per-space 备份导出的表（都有 space_id 列，按它过滤）。
 *  **不含审计表**（connection_events / entrance_activity）：只追加、无业务语义，且
 *  主键是 AUTOINCREMENT 整数——导入时用原 id 会撞上别的空间的行并被 REPLACE 覆盖。
 *  **不含 entrances / push_tokens**：它们没有 space_id，靠 partner_id/entrance_id 反查。 */
const SPACE_TABLES = [
  "spaces",
  "space_members",
  "join_tokens",
  "receipts",
  "key_escrow",
  "messages",
  "attachments",
  "sessions",
  "challenges",
] as const;

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));

export interface BackupPaths {
  db: string; // einz.sqlite.db 路径
  files: string; // 附件根目录
  dataDir: string; // <data>/ 根目录（backups/ 也在这里）
}

/** 从环境变量解析备份路径（与 app.ts / db.ts 默认值一致）。 */
export function resolveBackupPaths(env: NodeJS.ProcessEnv = process.env): BackupPaths {
  const db = env.EINZ_DB ?? resolve(HERE, "../data/einz.sqlite.db");
  const files = env.EINZ_FILES ?? resolve(HERE, "../data/files");
  const dataDir = resolve(dirname(db));
  return { db, files, dataDir };
}

function backupKey(): Buffer {
  const raw = process.env.EINZ_DB_BACKUP_KEY;
  if (!raw) throw new Error("EINZ_DB_BACKUP_KEY 未设置（应为 base64 32B），拒绝备份");
  const key = Buffer.from(raw, "base64");
  if (key.length !== 32) throw new Error("EINZ_DB_BACKUP_KEY 必须为 base64(32B)");
  return key;
}

function collectFilesRecursive(dir: string, base: string): { path: string; data: Buffer }[] {
  if (!existsSync(dir)) return [];
  const out: { path: string; data: Buffer }[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...collectFilesRecursive(full, base));
    } else {
      out.push({ path: relative(base, full).split("\\").join("/"), data: readFileSync(full) });
    }
  }
  return out;
}

/** 导出**单个空间**的行（逻辑导出，非整库物理备份）：按 space_id 过滤，
 *  entrances/push_tokens 靠 partner_id/entrance_id 反查带出。 */
function exportSpaceRows(spaceId: string): Record<string, Record<string, unknown>[]> {
  assertSafeSpaceId(spaceId);
  const db = getDb();
  const rows: Record<string, Record<string, unknown>[]> = {};
  for (const table of SPACE_TABLES) {
    rows[table] = db.prepare(`SELECT * FROM ${table} WHERE space_id = ?`).all(spaceId) as Record<string, unknown>[];
  }
  // 设备（登记项）没有 space_id：走 partner_id → space_members 反查
  const entrances = db
    .prepare(
      `SELECT * FROM entrances WHERE partner_id IN
       (SELECT partner_id FROM space_members WHERE space_id = ? AND partner_id IS NOT NULL)`,
    )
    .all(spaceId) as Record<string, unknown>[];
  rows.entrances = entrances;
  // push_tokens 挂在 entrance_id 上
  const ids = entrances.map((d) => d.entrance_id as string);
  rows.push_tokens = ids.length === 0
    ? []
    : (db
        .prepare(`SELECT * FROM push_tokens WHERE entrance_id IN (${ids.map(() => "?").join(",")})`)
        .all(...ids) as Record<string, unknown>[]);
  return rows;
}

/** 创建加密备份，返回备份文件路径。
 *  [spaceId] 给出时做 **per-space 备份**：只导出该空间的行 + `files/<space_id>/`（不做
 *  整库物理备份，恢复时也只覆盖该空间，不动别的空间——老板 2026-09-23）。 */
export async function createBackup(paths = resolveBackupPaths(), spaceId?: string): Promise<string> {
  const key = backupKey();
  const now = Date.now();
  const backupsDir = join(paths.dataDir, "backups");
  mkdirSync(backupsDir, { recursive: true });

  // per-space：逻辑导出（行 JSON + 该空间的文件），不整库物理备份
  if (spaceId != null && spaceId.length > 0) {
    assertSafeSpaceId(spaceId);
    const spaceFiles = join(paths.files, spaceId);
    const entries = collectFilesRecursive(spaceFiles, spaceFiles).map((f) => ({
      // 备份内路径统一带 files/<space_id>/ 前缀，恢复时按同一规则剥前缀
      path: `files/${spaceId}/${f.path}`,
      b64: f.data.toString("base64"),
    }));
    const payload = JSON.stringify({
      format: FORMAT,
      created_at: now,
      scope: { type: "space", space_id: spaceId },
      rows: exportSpaceRows(spaceId),
      entries,
    });
    return encryptBackup(payload, now, backupsDir, `space-${spaceId}`);
  }

  // 1) SQLite 官方 Backup API 在线备份 einz.sqlite.db（读写中也可安全备份）
  const tmpDb = join(paths.dataDir, `backup-db-${now}.tmp`);
  const db = new Database(paths.db, { readonly: true });
  try {
    await db.backup(tmpDb);
  } finally {
    db.close();
  }
  const dbBytes = readFileSync(tmpDb);
  rmSync(tmpDb, { force: true });

  // 2) 组装 payload：db + files/（v1 的 config.json 白名单条目已删，见文件头）
  const entries = [
    { path: "app.db", data: dbBytes },
    ...collectFilesRecursive(paths.files, paths.files),
  ];
  const payload = JSON.stringify({
    format: FORMAT,
    created_at: now,
    scope: { type: "all" },
    entries: entries.map((e) => ({ path: e.path, b64: e.data.toString("base64") })),
  });
  return encryptBackup(payload, now, backupsDir);
}

/** 加密落盘（全量 / per-space 共用）。[tag] 进文件名，便于运维一眼区分
 *  （`backup-<tag>-<ts>.json`；全量为 `backup-<ts>.json`）。 */
function encryptBackup(payload: string, now: number, backupsDir: string, nameTag?: string): string {
  const key = backupKey();

  // 3) AES-256-GCM 加密
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(payload, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  const backupFile = {
    format: FORMAT,
    created_at: now,
    nonce: nonce.toString("base64"),
    tag: tag.toString("base64"),
    data: ciphertext.toString("base64"),
  };
  const outPath = join(backupsDir, nameTag == null ? `backup-${now}.json` : `backup-${nameTag}-${now}.json`);
  writeFileSync(outPath, JSON.stringify(backupFile, null, 2));
  return outPath;
}

/** 打开并解密备份（全量 / per-space 共用），返回解析后的 payload。 */
function openBackup(backupPath: string): {
  created_at: number;
  scope: { type: string; space_id?: string };
  rows?: Record<string, Record<string, unknown>[]>;
  entries: { path: string; b64: string }[];
} {
  const key = backupKey();
  const file = JSON.parse(readFileSync(backupPath, "utf8")) as {
    format: string;
    nonce: string;
    tag: string;
    data: string;
  };
  if (file.format !== FORMAT) throw new Error(`备份格式不兼容: ${file.format}`);
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(file.nonce, "base64"));
  decipher.setAuthTag(Buffer.from(file.tag, "base64"));
  const payload = Buffer.concat([
    decipher.update(Buffer.from(file.data, "base64")),
    decipher.final(),
  ]).toString("utf8");
  const parsed = JSON.parse(payload) as {
    created_at: number;
    scope?: { type: string; space_id?: string };
    rows?: Record<string, Record<string, unknown>[]>;
    entries: { path: string; b64: string }[];
  };
  return {
    created_at: parsed.created_at,
    scope: parsed.scope ?? { type: "all" }, // 旧备份无 scope 字段 → 视为全量
    rows: parsed.rows,
    entries: parsed.entries,
  };
}

/** **恢复单个空间**：只清并覆盖该空间的行与文件，别的空间与审计表不动。
 *  与全量恢复的区别：不删库文件、不清整个 files/——所以可以在线做（但请在停写时做，
 *  否则并发写入会与 DELETE/INSERT 交错）。 */
function restoreSpace(
  spaceId: string,
  rows: Record<string, Record<string, unknown>[]>,
  entries: { path: string; b64: string }[],
  paths: BackupPaths,
): void {
  assertSafeSpaceId(spaceId);
  const db = getDb();
  // 删除顺序：子表先行（外键若启用也不会撞约束）；审计表刻意不动
  const cleanup = db.transaction(() => {
    db.prepare(`DELETE FROM push_tokens WHERE entrance_id IN (SELECT entrance_id FROM entrances WHERE partner_id IN (SELECT partner_id FROM space_members WHERE space_id = ? AND partner_id IS NOT NULL))`).run(spaceId);
    db.prepare(`DELETE FROM entrances WHERE partner_id IN (SELECT partner_id FROM space_members WHERE space_id = ? AND partner_id IS NOT NULL)`).run(spaceId);
    for (const table of ["attachments", "messages", "receipts", "join_tokens", "challenges", "sessions", "key_escrow", "space_members", "spaces"]) {
      db.prepare(`DELETE FROM ${table} WHERE space_id = ?`).run(spaceId);
    }
    for (const table of ["spaces", "space_members", "join_tokens", "receipts", "key_escrow", "messages", "attachments", "sessions", "challenges", "entrances", "push_tokens"]) {
      const list = rows[table] ?? [];
      for (const row of list) {
        const cols = Object.keys(row);
        if (cols.length === 0) continue;
        db.prepare(
          `INSERT OR REPLACE INTO ${table} (${cols.join(",")}) VALUES (${cols.map(() => "?").join(",")})`,
        ).run(...cols.map((c) => row[c]));
      }
    }
  });
  cleanup();

  // 文件：先清该空间目录（恢复成备份时的精确状态），再写回
  const spaceFiles = join(paths.files, spaceId);
  if (existsSync(spaceFiles)) rmSync(spaceFiles, { recursive: true, force: true });
  for (const entry of entries) {
    const rel = entry.path.startsWith(`files/${spaceId}/`)
      ? entry.path.slice(`files/${spaceId}/`.length)
      : entry.path;
    const target = join(spaceFiles, rel);
    assertInsideRoot(paths.files, target);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, Buffer.from(entry.b64, "base64"));
  }
}

/**
 * 确保落盘路径仍在 root 之内（纵深防御，同 attachments.assertInsideFilesRoot）。
 *
 * 为什么需要（2026-09-15 评审）：备份条目里的 `path` 是**备份文件里自带的字符串**，
 * 恢复时 `join(paths.files, entry.path.slice("files/".length))` 直接落盘——一份
 * `files/../../etc/xxx` 就能写到附件根目录之外。缓解是备份包本身有 AES-256-GCM
 * 认证（伪造需要备份密钥），但这类越界读写的防线不该只靠"上游可信"。
 * 正常备份路径由 `relative()` 产出，本就干净，所以这里的约束不会误伤。
 */
function assertInsideRoot(root: string, candidate: string): void {
  // 用 resolve + 分隔符拼接，避免 Windows（resolve 返回 \）与 "/" 混用误判
  const prefix = resolve(root) + sep;
  if (!resolve(candidate).startsWith(prefix)) {
    throw new Error(`备份条目路径逃出根目录（拒绝恢复）: ${candidate}`);
  }
}

/** 从加密备份恢复：解密 → 写回 einz.sqlite.db / files/。
 *  per-space 备份（scope.type === 'space'）走另一条路：只覆盖该空间，不动别的空间。 */
export function restoreBackup(backupPath: string, paths = resolveBackupPaths()): void {
  const opened = openBackup(backupPath);
  const parsed = { entries: opened.entries };

  // per-space：只覆盖该空间的行与文件目录（库文件与别的空间都不动）
  if (opened.scope.type === "space" && opened.scope.space_id != null) {
    restoreSpace(opened.scope.space_id, opened.rows ?? {}, opened.entries, paths);
    return;
  }

  // 先清空旧 files/（恢复为备份时的精确状态）
  if (existsSync(paths.files)) rmSync(paths.files, { recursive: true, force: true });

  // 库：连 -wal / -shm 一起删——只覆盖主库的话，残留的 WAL 会被 SQLite 重放进
  // 刚恢复的库里，恢复出"半新半旧"的数据（老板 2026-09-17）。
  for (const suffix of ["", "-wal", "-shm"]) rmSync(paths.db + suffix, { force: true });

  for (const entry of parsed.entries) {
    // `app.db` 是**精确等值匹配**（条目名只是内部标签，落盘位置取 paths.db，
    // 即 EINZ_DB / 默认 einz.sqlite.db——此前写成同名 app.db，服务读不到，恢复等于没恢复）。
    if (entry.path === "app.db") {
      mkdirSync(dirname(paths.db), { recursive: true });
      writeFileSync(paths.db, Buffer.from(entry.b64, "base64"));
      continue;
    }
    // 其余一律当附件：备份里的路径是 files/ 内的相对路径，早期备份可能带
    // `files/` 前缀也可能不带（两种都认）。路径来自备份文件 → 必须校验落盘位置，
    // 否则一份 `../../etc/xxx` 就能写到附件根目录之外。
    const relative = entry.path.startsWith("files/")
      ? entry.path.slice("files/".length)
      : entry.path;
    const fileTarget = join(paths.files, relative);
    assertInsideRoot(paths.files, fileTarget);
    mkdirSync(dirname(fileTarget), { recursive: true });
    writeFileSync(fileTarget, Buffer.from(entry.b64, "base64"));
  }
}

/** 列出 backups/ 目录中的备份文件。 */
export function listBackups(paths = resolveBackupPaths()): string[] {
  const dir = join(paths.dataDir, "backups");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => n.startsWith("backup-") && n.endsWith(".json"))
    .map((n) => join(dir, n));
}

/** 演练辅助：确认备份文件可解（不写回，仅验证完整性）。 */
export function verifyBackup(
  backupPath: string,
  paths = resolveBackupPaths(),
): { created_at: number; scope: { type: string; space_id?: string }; entries: string[] } {
  const opened = openBackup(backupPath);
  return {
    created_at: opened.created_at,
    scope: opened.scope,
    entries: opened.entries.map((e) => e.path),
  };
}
