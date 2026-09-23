import 'app_lock.dart';
import 'attachment_store.dart';
import 'local_database.dart';
import 'media_cache.dart';
import 'secure_store.dart';
import 'vault_session.dart';

/// 清空本设备全部本地数据，回到"新设备"状态。
///
/// 由界面入口触发：对话页菜单 → 高级 → 重置本机（`widgets/reset_install.dart`）。
/// 开发时用 `--server` 连开发服务器测完之后，本机的 `spaceId` / `token` / 通道密钥对
/// 都属于那台开发服务器——连回生产既用不了，也需要一个出口清库重新入网。
///
/// 清的范围：
/// - drift 全表：消息、附件元数据、同步锚点、草稿、回执、`spaces`（空间列表——漏了
///   它，重置后空间切换器里会留着已经不存在的旧空间）、`app_state`（含锁包、
///   profile、安装标记）；
/// - 系统安全存储里的明文密钥包（`SecureStore`）——漏掉的话"跳过 PIN"的配置会把
///   人直接拖回聊天页，等于没清；
/// - 附件明文缓存：长期留存目录（`AttachmentStore`）+ 临时缓存（`MediaCache`）
///   都要删，否则留一地明文。
///
/// **按行删除而不是删库文件**：`LocalDatabase.shared` 是静态单例，删文件要先
/// close、close 之后不能再复用；按行删则本次进程可以继续跑，清完直接进向导。
Future<void> resetLocalData(LocalDatabase db) async {
  await db.delete(db.localMessages).go();
  await db.delete(db.localAttachments).go();
  await db.delete(db.syncState).go();
  await db.delete(db.drafts).go();
  await db.delete(db.peerReceipts).go();
  await db.delete(db.spaces).go(); // 空间列表：不清则重置后切换器里仍是旧空间
  await db.delete(db.appState).go();
  await SecureStore.deleteAll(AppLockService.secureKeys);
  await AttachmentStore.clear();
  await MediaCache.deleteAll();
  VaultSession.publish(null); // 解锁态也一并清掉（内存里别留着已经删掉的密钥）
}
