/**
 * 备份 CLI：npm run backup [-- --verify] [-- --space <space_id>]
 * 产出加密备份到 <data>/backups/backup-<ts>.json（per-space 时文件名带 space 标签），
 * 并打印文件列表。
 * 依赖环境变量：EINZ_DB / EINZ_FILES（可选，有默认值）、
 *               EINZ_DB_BACKUP_KEY（必需，base64 32B）。
 *
 * --space：只备份该空间的行 + files/<space_id>/（恢复时也只覆盖该空间）。
 */
import { createBackup, listBackups, resolveBackupPaths, verifyBackup } from "../src/backup.js";

const verify = process.argv.includes("--verify");
const spaceIdx = process.argv.indexOf("--space");
const spaceId = spaceIdx >= 0 ? process.argv[spaceIdx + 1] : undefined;
if (spaceIdx >= 0 && (spaceId == null || spaceId.startsWith("--"))) {
  console.error("用法: npm run backup -- [--verify] [--space <space_id>]");
  process.exit(1);
}

const out = await createBackup(resolveBackupPaths(), spaceId);
console.log(`✅ 备份已创建: ${out}${spaceId == null ? "" : `（仅空间 ${spaceId}）`}`);
if (verify) {
  const info = verifyBackup(out);
  console.log(`   完整性校验通过: ${info.entries.length} 个文件（${info.entries.join(", ")}）`);
}
const all = listBackups();
console.log(`现有备份 ${all.length} 个:`);
for (const b of all) console.log(`  - ${b}`);
