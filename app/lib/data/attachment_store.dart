import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'dev_data_dir.dart';
import 'media_cache.dart';

/// 附件明文**长期存放**目录（`stored` 模式用）。
///
/// 与 [MediaCache]（临时缓存，随时可清）的区别：这里的文件要跨会话活下来，
/// 所以路径必须**确定 + 不备份**：
/// - 位置：平台的"不备份"私有目录——iOS 取 Application Support 并设
///   `NSURLIsExcludedFromBackupKey`，Android 取 `noBackupFilesDir`；两者由
///   `einz/store` MethodChannel 提供（原生见 AppDelegate.swift / MainActivity.kt）。
///   原生不可用时回落到 [getApplicationSupportDirectory]（测试/未适配平台）。
/// - **明文绝不能进 iCloud / Google 备份**：备份里出现明文等于绕过本机安全边界，
///   换机还原就能读到旧附件（与 app_lock 里 `first_unlock_this_device` 的取舍一致）。
/// - 文件名复用 [MediaCache.cacheFileName]（messageId + 扩展名，经 safeName 白名单化，
///   杜绝路径越出目录——扩展名来自对端可控的密文正文）。
///
/// 所有方法**尽力而为**：平台不可用/文件系统错误一律静默——存储卫生不阻塞聊天。
class AttachmentStore {
  AttachmentStore._();

  static const _channel = MethodChannel('einz/store');
  static const _subDir = 'einz_media';

  static Directory? _dir;

  /// 存放目录（缓存；不存在则创建）。平台不可用返回 null。
  static Future<Directory?> directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    try {
      final path = await _channel.invokeMethod<String>('getStoredDir');
      if (path != null && path.isNotEmpty) {
        return _dir = await _ensure(Directory(path));
      }
    } on MissingPluginException {
      // 测试环境/未适配平台：回落到 path_provider
    } catch (_) {
      // 其它平台异常：同样回落
    }
    try {
      return _dir = await _ensure(await applyDevDataDir(getApplicationSupportDirectory));
    } catch (_) {
      return null; // 平台不可用：调用方按"没有本地副本"处理
    }
  }

  static Future<Directory> _ensure(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 确定性路径（不创建文件）；平台不可用返回 null。
  static Future<File?> pathFor(String messageId, String ext) async {
    final dir = await directory();
    if (dir == null) return null;
    return File('${dir.path}/${MediaCache.cacheFileName(messageId, ext)}');
  }

  /// 本地已有且文件仍在 → 直接返回（零网络、零解密）；否则用 [load] 生成并落盘。
  /// 失败（无目录/下载失败）返回 null——调用方按"没有本地副本"处理并可重试。
  static Future<File?> ensure(
    String messageId,
    String ext,
    Future<Uint8List> Function() load,
  ) async {
    try {
      final file = await pathFor(messageId, ext);
      if (file == null) return null;
      if (await file.exists()) return file;
      final bytes = await load();
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// 定点删除某条消息的留存明文（消息删除 / 阅后即焚到期时调用）。
  static Future<void> deleteFor(String messageId) async {
    try {
      final dir = await directory();
      if (dir == null) return;
      // cacheFileName 形如 `einz_media_<id>.<ext>`，按 `einz_media_<id>.` 前缀匹配
      final target = MediaCache.cacheFileName(messageId, '');
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.uri.pathSegments.last.startsWith(target)) {
          await entity.delete().catchError((_) => entity);
        }
      }
    } catch (_) {
      // 平台不可用/文件系统错误：忽略
    }
  }

  /// 清空所有留存明文（切回 `secured` 模式 / 设备被撤销时调用）。
  static Future<void> clear() async {
    try {
      final dir = await directory();
      if (dir == null) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.uri.pathSegments.last.startsWith(MediaCache.fileNamePrefix)) {
          await entity.delete().catchError((_) => entity);
        }
      }
    } catch (_) {
      // 同上：忽略
    }
  }

  /// 测试用：清掉目录缓存（下次调用重新解析平台目录）。
  static void resetForTest() => _dir = null;

  /// 子目录名（原生侧同名的那一级；仅供测试/诊断）。
  static String get subDirName => _subDir;
}
