/**
 * 恢复 CLI：npm run restore -- <备份文件路径>
 * 解密备份并写回 einz.sqlite.db / files/ / config.json。
 * ⚠️ 会覆盖现有数据，执行前请确认。
 */
import { restoreBackup, resolveBackupPaths } from "../src/backup.js";

const file = process.argv[2];
if (!file) {
  console.error("用法: npm run restore -- <备份文件路径>");
  process.exit(1);
}
restoreBackup(file, resolveBackupPaths());
console.log(`✅ 已从备份恢复: ${file}`);
