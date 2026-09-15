import 'package:flutter/widgets.dart';

import 'local_database.dart';

/// 附件存储模式：**本设备**设置（存 app_state，不同步到空间——一台设备一个选择，
/// 伴侣那台可以跟你不一样）。它是"安全 vs 体验"的取舍开关：
///
/// - `secured`：**不留存**解密后的明文。附件按需下载，
///   解密字节只进临时缓存（进程退出/系统清理即失效），下次打开消息流重新下载。
/// - `stored`（**默认**，老板 2026-09-15：更符合日常习惯）：**留存**解密后的明文
///   （App 私有目录且**不进系统备份**）——
///   消息流里直接打开本地内容；万一文件被清掉，消息上给"点击重新下载"。
///
/// 注意：切换模式只影响**之后**的行为与清理策略，见 [AttachmentStore]。
const List<String> kAttachmentStorageOptions = ['secured', 'stored'];

/// 切换通知：聊天页监听后即时生效（点选即切换）。
final ValueNotifier<String> attachmentStorageNotifier =
    ValueNotifier<String>('stored');

/// 附件存储模式设置（存本设备 app_state，key='attachment_storage'）。
class AttachmentStorageSettings {
  AttachmentStorageSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'attachment_storage';

  /// 当前模式（默认 'stored' = 长期保存，老板 2026-09-15；老版本升上来也是它）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey)))
        .getSingleOrNull();
    final v = row?.value;
    return (v == null || !kAttachmentStorageOptions.contains(v)) ? 'stored' : v;
  }

  /// 保存模式并通知即时生效。**切回 secured 时由调用方负责清空已存明文**
  /// （[AttachmentStore.clear]）——否则"安全"名不副实（老板 2026-09-14 定）。
  Future<void> save(String mode) async {
    assert(kAttachmentStorageOptions.contains(mode), '非法附件存储模式: $mode');
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _kKey, value: mode));
    attachmentStorageNotifier.value = mode;
  }
}
