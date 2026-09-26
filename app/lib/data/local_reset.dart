import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_lock.dart';
import 'attachment_store.dart';
import 'dev_data_dir.dart';
import 'local_database.dart';
import 'media_cache.dart';
import 'secure_store.dart';
import 'space_session.dart';
import 'vault_session.dart';

/// 清空**整机**全部本地数据，回到"新设备"状态（"整机清空"原语）。
///
/// **当前没有 UI 入口**：界面上能做的破坏性操作是空间级的「销毁本通道」
/// （`widgets/reset_entrance.dart` 的 `confirmLeaveSpace` → `removeSpace`，只清一个空间）。
/// 本函数留给"整机重来"：开发时用 `--server` 连开发服务器测完之后，本机的
/// `spaceId` / `token` / 通道密钥对都属于那台开发服务器——连回生产既用不了，
/// 也需要一个出口清库重新入网。
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
  SpaceSessions.clear(); // 会话（含续期闭包）也不能留着——凭证已经删了
}

/// **兜底清空**（当 [resetLocalData] 本身失败时用——本地库**打不开**：迁移抛错 / 文件
/// 损坏）。`resetLocalData` 是按行删、经 drift 走，库打不开就没法删；这里改成
/// **关连接 + 删库文件**（含 `-wal`/`-shm`，dev 隔离目录同款路径）+ 清安全存储与缓存。
///
/// ⚠️ drift 的 `LazyDatabase` 一旦 `close()` **不能重开**，故调用后本进程的
/// `LocalDatabase` 不可再用——调用方**必须退出/重启 App**（下次启动是全新安装）。
///
/// 用途：`StartupGate` 启动失败页的「清除本机数据并重来」逃生口（2026-09-24 老板同意）。
Future<void> hardResetLocalData(LocalDatabase db) async {
  // 1) 释放库连接（关不掉也要继续删文件，尽力而为）
  try {
    await db.close();
  } catch (_) {}
  // 2) 删库文件：drift_flutter 固定 `<Documents|dev-/ >/einz.sqlite`
  try {
    final dir = devDataDirIsolated
        ? await devSubDir(getApplicationDocumentsDirectory)
        : await getApplicationDocumentsDirectory();
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = File('${dir.path}${Platform.pathSeparator}einz.sqlite$suffix');
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  // 3) 安全存储 + 附件/媒体明文缓存 + 内存解锁态
  try {
    await SecureStore.deleteAll(AppLockService.secureKeys);
  } catch (_) {}
  try {
    await AttachmentStore.clear();
  } catch (_) {}
  try {
    await MediaCache.deleteAll();
  } catch (_) {}
  VaultSession.publish(null);
  SpaceSessions.clear();
}
