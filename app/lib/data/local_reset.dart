import 'app_lock.dart';
import 'attachment_store.dart';
import 'local_database.dart';
import 'media_cache.dart';
import 'secure_store.dart';

/// 清空本设备全部本地数据，回到"新设备"状态。
///
/// 由桌面端 `--reset` 启动参数触发（见 `main.dart`）：开发时用 `--server` 连开发
/// 服务器测完之后，本机的 `spaceId` / `token` / 设备密钥对都属于那台开发服务器——
/// 连回生产既用不了，也没有任何入口能卸掉，只能清库后重新入网。
///
/// 清的范围：
/// - drift 全表：消息、附件元数据、同步锚点、草稿、回执、`app_state`（含锁包、
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
  await db.delete(db.appState).go();
  await SecureStore.deleteAll(AppLockService.secureKeys);
  await AttachmentStore.clear();
  await MediaCache.deleteAll();
}
