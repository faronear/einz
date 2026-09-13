import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 附件解密缓存（语音/视频播放用，方案 1+2）。
///
/// 播放器（audioplayers/video_player）只认文件路径，解密后的明文必须落盘；
/// 本类统一管理这些缓存文件的生命周期：
/// - **确定性路径**（messageId + 扩展名）：同一消息重复播放直接复用，零重复解密
/// - **App 私有缓存目录**（getTemporaryDirectory，沙盒内，非公共目录）
/// - **定点删除**：消息焚毁/删除时删对应缓存（[deleteFor]）
/// - **孤儿清理**：启动时清掉本地库已无对应消息的缓存 + 历史遗留的 systemTemp 文件
///
/// 所有方法**尽力而为**：平台不可用（测试环境 MissingPluginException）或文件系统
/// 错误一律静默忽略——缓存卫生绝不阻塞聊天主流程。
class MediaCache {
  MediaCache._();

  static const _prefix = 'einz_media_';

  /// 历史遗留前缀（旧版直接写 Directory.systemTemp、时间戳命名，从未清理）。
  static const _legacyPrefixes = ['einz_audio_', 'einz_preview_'];

  /// 定点删除某条消息的缓存（焚毁/删除消息时调用）。
  static Future<void> deleteFor(String messageId) async {
    await _guard(() async {
      final dir = await _cacheDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (_isOwned(name) && name.startsWith('$_prefix$messageId.')) {
          await entity.delete().catchError((_) => entity);
        }
      }
    });
  }

  /// 全量清理（设备撤销清空本地数据时用）。
  static Future<void> deleteAll() async {
    await _guard(() async {
      final dir = await _cacheDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (_isOwned(name)) {
          await entity.delete().catchError((_) => entity);
        }
      }
    });
  }

  /// 启动孤儿清理：删除 [keepMessageIds] 之外的缓存文件；顺带清历史遗留的
  /// 旧版 systemTemp 文件（时间戳命名、从未清理过）。
  static Future<void> prune(Set<String> keepMessageIds) async {
    await _guard(() async {
      final dir = await _cacheDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!_isOwned(name)) continue;
        if (name.startsWith(_prefix)) {
          // einz_media_<messageId>.<ext>
          final rest = name.substring(_prefix.length);
          final dot = rest.lastIndexOf('.');
          final messageId = dot > 0 ? rest.substring(0, dot) : rest;
          if (!keepMessageIds.contains(messageId)) {
            await entity.delete().catchError((_) => entity);
          }
        } else {
          // 遗留前缀文件：无索引可查，一律视为孤儿
          await entity.delete().catchError((_) => entity);
        }
      }
      // 旧版写在 Directory.systemTemp 的文件（可能与缓存目录不同）：同样清一遍
      final systemTemp = Directory.systemTemp;
      if (systemTemp.path != dir.path) {
        await for (final entity in systemTemp.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (_legacyPrefixes.any(name.startsWith)) {
            await entity.delete().catchError((_) => entity);
          }
        }
      }
    });
  }

  /// 是否本类管辖的文件（含遗留前缀）——deleteAll/prune 只动自己的文件。
  static bool _isOwned(String name) =>
      name.startsWith(_prefix) || _legacyPrefixes.any(name.startsWith);

  /// App 私有缓存目录（iOS/Android 沙盒 cache；桌面为用户缓存目录）。
  static Future<Directory> _cacheDirectory() async =>
      getTemporaryDirectory();

  /// 尽力而为：平台不可用/文件系统错误静默忽略（缓存卫生不阻塞主流程）。
  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // 平台不可用（测试 MissingPluginException）或文件系统错误：忽略
    }
  }

  /// 缓存文件路径（确定性：messageId + 扩展名）。不创建文件。
  static Future<File> pathFor(String messageId, String ext) async {
    final dir = await _cacheDirectory();
    return File('${dir.path}/$_prefix$messageId.$ext');
  }

  /// 已有缓存则返回（重复播放零解密），否则用 [load] 生成并落盘。
  static Future<File> ensure(
    String messageId,
    String ext,
    Future<Uint8List> Function() load,
  ) async {
    final file = await pathFor(messageId, ext);
    if (await file.exists()) return file;
    final bytes = await load();
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
