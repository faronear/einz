import 'package:flutter/widgets.dart';

import 'local_database.dart';
import 'space_scoped_setting.dart';

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
///
/// 多空间：给 [spaceId] 时键为 `space.<spaceId>.attachment_storage`；读不到时回退
/// 旧全局键（存量设置没有空间维度）。「应用于本机所有秘境」的全局保存走 mixin 的
/// [saveAll]（见 [SpaceScopedSetting]）。
class AttachmentStorageSettings with SpaceScopedSetting {
  AttachmentStorageSettings(this.db, {this.spaceId});

  @override
  final LocalDatabase db;

  /// 归属空间；null = 用旧全局键。
  @override
  final String? spaceId;

  static const _kKey = 'attachment_storage';

  @override
  String get settingKey => _kKey;

  /// 当前模式（默认 'stored' = 长期保存，老板 2026-09-15；老版本升上来也是它）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(scopedKey)))
        .getSingleOrNull();
    final v = row?.value ?? (spaceId == null
        ? null
        : (await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull())?.value);
    return (v == null || !kAttachmentStorageOptions.contains(v)) ? 'stored' : v;
  }

  /// 保存模式（只写当前空间）并通知即时生效。**切回 secured 时由调用方负责清空
  /// 已存明文**（[AttachmentStore.clearSpace]——只清本空间那一份：模式是 per-space
  /// 设置，别空间的明文缓存不该被误删）——否则"安全"名不副实（老板 2026-09-14 定）。
  /// 勾了"所有秘境"时调用方走 [saveAll] + 全局 clear。
  Future<void> save(String mode) async {
    assert(kAttachmentStorageOptions.contains(mode), '非法附件存储模式: $mode');
    await writeSetting(scopedKey, mode);
    attachmentStorageNotifier.value = mode;
  }

  /// 全局保存（mixin 的 saveAll）+ 补一次即时生效通知——saveAll 不走 [save]，
  /// 不补的话菜单当前值/附件渲染要等重启才更新（当前空间的模式其实已变）。
  @override
  Future<void> saveAll(String mode) async {
    assert(kAttachmentStorageOptions.contains(mode), '非法附件存储模式: $mode');
    await super.saveAll(mode);
    attachmentStorageNotifier.value = mode;
  }
}
