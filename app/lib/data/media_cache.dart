import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'dev_data_dir.dart';

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

  /// 文件名统一前缀（长期存放目录 [AttachmentStore] 复用同一套命名）。
  static String get fileNamePrefix => _prefix;

  /// 历史遗留前缀（旧版直接写 Directory.systemTemp、时间戳命名，从未清理）。
  static const _legacyPrefixes = ['einz_audio_', 'einz_preview_'];

  /// 定点删除某条消息的缓存（焚毁/删除消息时调用）。
  static Future<void> deleteFor(String messageId) async {
    await _guard(() async {
      final dir = await _cacheDirectory();
      final target = '$_prefix${safeName(messageId)}.';
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (_isOwned(name) && name.startsWith(target)) {
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
      // 与 [cacheFileName] 同一套安全化：文件名里存的是 safeName(id)，保留集合也要
      // 同样处理，否则合法缓存会被误判成孤儿删掉
      final keep = {for (final id in keepMessageIds) safeName(id)};
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!_isOwned(name)) continue;
        if (name.startsWith(_prefix)) {
          final messageId = messageIdOf(name);
          if (messageId == null || !keep.contains(messageId)) {
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

  /// 文件名安全化：只允许 `[A-Za-z0-9._-]`，其余（尤其是 `/`、`\`）替换为 `_`。
  ///
  /// [pathFor] 的两个入参都不可信：`messageId` 来自服务器下发的消息信封，
  /// `ext` 来自**对端可控**的密文正文（音频消息取 `_extOf(plaintext)`）。若原样
  /// 拼路径，对端发一条 caption 为 `x.mp4/../../evil` 的语音，用户点播放即把解密
  /// 后的字节写到缓存目录之外（老板 2026-09-14 排查出的缺口）。
  /// `.` 保留但 `/` 被替换，且文件名恒以 [_prefix] 开头，故不可能形成 `..` 路径段。
  ///
  /// 别名 `safeName` 对测试可见（纯函数，便于单测）。
  static String safeName(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 缓存文件名（纯函数，便于单测）：`einz_media_<safe(id)>.<safe(ext)>`。
  /// 合法 id（UUID/38 位 hex-dash）经 [safeName] 后不变，既有缓存仍能命中。
  static String cacheFileName(String messageId, String ext) =>
      '$_prefix${safeName(messageId)}.${safeName(ext)}';

  /// 从缓存文件名反解（已安全化的）messageId；非本类命名返回 null。
  static String? messageIdOf(String fileName) {
    if (!fileName.startsWith(_prefix)) return null;
    final rest = fileName.substring(_prefix.length);
    final dot = rest.lastIndexOf('.');
    return dot > 0 ? rest.substring(0, dot) : rest;
  }

  /// 是否本类管辖的文件（含遗留前缀）——deleteAll/prune 只动自己的文件。
  static bool _isOwned(String name) =>
      name.startsWith(_prefix) || _legacyPrefixes.any(name.startsWith);

  /// App 私有缓存目录（iOS/Android 沙盒 cache；桌面为用户缓存目录）。
  ///
  /// **必须自己建目录**：macOS 桌面端 `getTemporaryDirectory()` 返回
  /// `<容器>/Data/Library/Caches/<bundle>`，但该目录**不一定存在**，且没有任何
  /// 东西会替你建（2026-09-20 实测：删掉后跑一轮 App 仍未重建；同一份代码在
  /// iOS/Android 上该目录恒存在，所以只在桌面端暴露）。不建目录 → 调用方的
  /// `writeAsBytes` 直接抛 FileSystemException → 视频内联预览/语音播放静默失败
  /// （老板报「桌面版视频在消息流里是空白」的真凶）。`create(recursive:)` 幂等，
  /// 已存在时是 no-op。
  static Future<Directory> _cacheDirectory() async {
    // dev 运行时（npm run app-mac-run-local*）落进 caches/dev-*/，不污染正式那份
    final dir = await applyDevDataDir(getTemporaryDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 尽力而为：平台不可用/文件系统错误静默忽略（缓存卫生不阻塞主流程）。
  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // 平台不可用（测试 MissingPluginException）或文件系统错误：忽略
    }
  }

  /// 缓存文件路径（确定性：messageId + 扩展名）。不创建文件。
  /// 文件名经 [safeName] 白名单化，杜绝路径越出缓存目录（见 [safeName]）。
  static Future<File> pathFor(String messageId, String ext) async {
    final dir = await _cacheDirectory();
    return File('${dir.path}/${cacheFileName(messageId, ext)}');
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
