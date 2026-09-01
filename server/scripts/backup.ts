/**
 * 备份 CLI：npm run backup [-- --verify]
 * 产出加密备份到 <data>/backups/backup-<ts>.json，并打印文件列表。
 * 依赖环境变量：EINZ_DB / EINZ_FILES / EINZ_CONFIG（可选，有默认值）、
 *               EINZ_DB_BACKUP_KEY（必需，base64 32B）。
 */
import { createBackup, listBackups, resolveBackupPaths, verifyBackup } from "../src/backup.js";

const verify = process.argv.includes("--verify");

const out = await createBackup(resolveBackupPaths());
console.log(`✅ 备份已创建: ${out}`);
if (verify) {
  const info = verifyBackup(out);
  console.log(`   完整性校验通过: ${info.entries.length} 个文件（${info.entries.join(", ")}）`);
}
const all = listBackups();
console.log(`现有备份 ${all.length} 个:`);
for (const b of all) console.log(`  - ${b}`);
