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

const FORMAT = "einz-server-backup-v1";

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

/** 创建加密备份，返回备份文件路径。 */
export async function createBackup(paths = resolveBackupPaths()): Promise<string> {
  const key = backupKey();
  const now = Date.now();
  const backupsDir = join(paths.dataDir, "backups");
  mkdirSync(backupsDir, { recursive: true });

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
    entries: entries.map((e) => ({ path: e.path, b64: e.data.toString("base64") })),
  });

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
  const outPath = join(backupsDir, `backup-${now}.json`);
  writeFileSync(outPath, JSON.stringify(backupFile, null, 2));
  return outPath;
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

/** 从加密备份恢复：解密 → 写回 einz.sqlite.db / files/。 */
export function restoreBackup(backupPath: string, paths = resolveBackupPaths()): void {
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
  const payload = Buffer.concat([decipher.update(Buffer.from(file.data, "base64")), decipher.final()]).toString("utf8");
  const parsed = JSON.parse(payload) as { entries: { path: string; b64: string }[] };

  // 先清空旧 files/（恢复为备份时的精确状态）
  if (existsSync(paths.files)) rmSync(paths.files, { recursive: true, force: true });

  for (const entry of parsed.entries) {
    // 注：`app.db` 是**精确等值匹配**，路径不受条目内容影响，无需约束；
    // 真正的缺口只在 files/ 分支（前缀匹配 + 截断拼接）。
    if (entry.path.startsWith("files/")) {
      const fileTarget = join(paths.files, entry.path.slice("files/".length));
      assertInsideRoot(paths.files, fileTarget);
      mkdirSync(dirname(fileTarget), { recursive: true });
      writeFileSync(fileTarget, Buffer.from(entry.b64, "base64"));
      continue;
    }
    if (entry.path === "app.db") {
      const target = join(paths.dataDir, entry.path);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, Buffer.from(entry.b64, "base64"));
    }
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
export function verifyBackup(backupPath: string, paths = resolveBackupPaths()): { created_at: number; entries: string[] } {
  const key = backupKey();
  const file = JSON.parse(readFileSync(backupPath, "utf8")) as {
    format: string;
    created_at: number;
    nonce: string;
    tag: string;
    data: string;
  };
  if (file.format !== FORMAT) throw new Error(`备份格式不兼容: ${file.format}`);
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(file.nonce, "base64"));
  decipher.setAuthTag(Buffer.from(file.tag, "base64"));
  const payload = Buffer.concat([decipher.update(Buffer.from(file.data, "base64")), decipher.final()]).toString("utf8");
  const parsed = JSON.parse(payload) as { entries: { path: string; b64: string }[] };
  return { created_at: file.created_at, entries: parsed.entries.map((e) => e.path) };
}
