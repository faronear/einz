import 'package:flutter/widgets.dart';

import 'local_database.dart';

/// 附件存储模式：**本设备**设置（存 app_state，不同步到空间——一台设备一个选择，
/// 伴侣那台可以跟你不一样）。它是"安全 vs 体验"的取舍开关：
///
/// - `secured`（默认，即现有行为）：**不留存**解密后的明文。附件按需下载，
///   解密字节只进临时缓存（进程退出/系统清理即失效），下次打开消息流重新下载。
/// - `stored`：**留存**解密后的明文（App 私有目录且**不进系统备份**）——
///   消息流里直接打开本地内容；万一文件被清掉，消息上给"点击重新下载"。
///
/// 注意：切换模式只影响**之后**的行为与清理策略，见 [AttachmentStore]。
const List<String> kAttachmentStorageOptions = ['secured', 'stored'];

/// 选项标签（菜单当前值 / 弹窗直接用）。
const Map<String, String> kAttachmentStorageLabels = {
  'secured': '安全（不留存）', // Secure (no local copy)
  'stored': '留存（直接打开）', // Keep (open instantly)
};

/// 选项描述（一句话，弹窗中展示）。
const Map<String, String> kAttachmentStorageDescriptions = {
  'secured': '每次打开都重新下载，本机不留明文副本', // Re-download each time; no plaintext kept
  'stored': '下载过的附件明文留在本机，消息流里直接打开（不进系统备份）',
  // Keep decrypted files on device; open instantly (excluded from backups)
};

/// 切换通知：聊天页监听后即时生效（点选即切换）。
final ValueNotifier<String> attachmentStorageNotifier =
    ValueNotifier<String>('secured');

/// 附件存储模式设置（存本设备 app_state，key='attachment_storage'）。
class AttachmentStorageSettings {
  AttachmentStorageSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'attachment_storage';

  /// 当前模式（默认 'secured' = 与本次功能前完全一致的行为）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey)))
        .getSingleOrNull();
    final v = row?.value;
    return (v == null || !kAttachmentStorageOptions.contains(v)) ? 'secured' : v;
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
