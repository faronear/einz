/**
 * 恢复 CLI：npm run restore -- <备份文件路径>
 * 解密备份并写回 einz.sqlite.db / files/。
 * ⚠️ 会覆盖现有数据，执行前请确认。
 */
import { restoreBackup, resolveBackupPaths, verifyBackup } from "../src/backup.js";

const file = process.argv[2];
if (!file) {
  console.error("用法: npm run restore -- <备份文件路径>");
  process.exit(1);
}
const info = verifyBackup(file);
if (info.scope.type === "space" && info.scope.space_id != null) {
  console.log(`ℹ️  这是**单空间**备份（${info.scope.space_id}）：只覆盖该空间，别的空间不受影响`);
} else {
  console.log("⚠️ 这是**全量**备份：会覆盖整个库与 files/");
}
restoreBackup(file, resolveBackupPaths());
console.log(`✅ 已从备份恢复: ${file}`);
