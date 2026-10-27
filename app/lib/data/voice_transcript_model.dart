import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show ByteData;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// SenseVoice-Small int8 模型分发器（20261009_voiceTranscript.zhcn.md §11）。
///
/// 定位（2026-10-12 改回「打包进产物」）：模型二进制**不进 git**，由
/// `scripts/fetchVoiceModel.sh` 在构建前拉取到 `app/assets/voice_model/`，
/// 随 App 打包分发；运行时**首次转写前**由 [ensureInstalled] 装到应用支持
/// 目录 `voice_transcript/<kModelVersion>/`，此后 [installedDir] 直接命中
/// 本地文件（离线可用）。
///
/// - 装模型三级解析：已装过 → 直接用；包内有资产 → 拷进应用目录（分块进度、
///   可取消、大小校验）；包里没有（dev 构建没跑 fetch 脚本）→ **回落下载**；
/// - 下载兜底双源：默认走 hf-mirror.com（中国大陆可达），失败回落 huggingface.co；
/// - 下载断点续传：`.part` 临时文件按已收字节 Range 续传（仅对**同一主机**有效——
///   换主机/换 Range 语义不可靠，切换前清掉 .part 重下；跨重启重试总是先试
///   hf-mirror，所以续传仍然生效）；
/// - 下载完整性：大小 + sha256 边下边算（不把 239MB 读进内存），基线见 [_files]
///   ——模型仓库文件不可变，版本变化走 [kModelVersion] 新目录，永不覆盖；
/// - 原子性：全部文件就绪后才写 `.ok` 标记；不完整目录 [installedDir]
///   视为未安装，下次重装。
class VoiceTranscriptModel {
  VoiceTranscriptModel._();

  /// 与 VoiceTranscriptService.kModelVersion 同值（行里 model_version 与
  /// 目录版本必须同步演进，服务侧直接引用本常量，单一事实来源）。
  static const String kModelVersion = '2024-07-17-int8';

  /// 包内资产前缀（pubspec `assets/voice_model/` 声明；fetchVoiceModel.sh
  /// 拉取落地处）。运行时经 rootBundle 读，首次转写拷进应用目录。
  static const String _bundledPrefix = 'assets/voice_model';

  /// HF 仓库（模型 + tokens 同仓）。
  static const String _repo =
      'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';

  /// 需要下载的文件（相对模型目录）。int8 模型 228MB（fp32 的 model.onnx
  /// ≈913MB，绝不下载）；tokens.txt 308KB。sha256 为 2026-10-10 基线：
  /// model 的取 HF LFS oid（= 文件内容 sha256），tokens 本地实测。
  /// 与 scripts/fetchVoiceModel.sh 的基线对齐——改模型两处一起改。
  static const List<({String name, int size, String sha256})> _files = [
    (
      name: 'model.int8.onnx',
      size: 239233841,
      sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    ),
    (
      name: 'tokens.txt',
      size: 315894,
      sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    ),
  ];

  /// 下载总字节数（进度条分母）。
  static int get totalBytes => _files.fold(0, (sum, f) => sum + f.size);

  /// 模型根目录：`<ApplicationSupport>/voice_transcript/<kModelVersion>/`。
  /// 测试/未适配平台（getApplicationSupportDirectory 抛错）返回 null。
  ///
  /// 路径构成的平台差异（2026-10-12 查证）：macOS 上 path_provider_foundation
  /// 会给 ApplicationSupport **拼上 bundle id**（沙盒容器内即
  /// `…/Application Support/cc.tic.einz/voice_transcript/…`；iOS 不拼、
  /// Android 的 ApplicationSupport = filesDir）。这里**不套**
  /// applyDevDataDir 是刻意的：模型是派生缓存而非用户数据，dev/生产共用一份
  ///比分存两份好（要隔离的是 DB/附件/密钥，见 dev_data_dir.dart）。
  static Future<Directory?> _rootDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, 'voice_transcript', kModelVersion));
    } catch (_) {
      return null;
    }
  }

  /// 已安装的模型目录（两文件 + .ok 标记齐全）；未装完/平台不支持 → null。
  static Future<String?> installedDir() async {
    final root = await _rootDir();
    if (root == null || !root.existsSync()) return null;
    for (final f in _files) {
      final file = File(p.join(root.path, f.name));
      if (!file.existsSync() || file.lengthSync() != f.size) return null;
    }
    if (!File(p.join(root.path, '.ok')).existsSync()) return null;
    return root.path;
  }

  /// 模型是否就绪（供 UI 决定「直接转写」还是「先准备」）。
  static Future<bool> isReady() async => await installedDir() != null;

  /// 模型就绪的唯一入口（首次转写前由 ChatPage 调用，带进度对话框）。
  ///
  /// 三级解析：① 已装过 → 直接返回；② **包内有资产**（正常发布构建）→
  /// 拷进应用目录（分块进度、可取消、大小校验）；③ 包里没有（dev 构建
  /// 没跑 fetch 脚本）→ 回落 [ensureDownloaded] 下载兜底。
  ///
  /// [onProgress] 收 (已完成字节, 总字节)——两种路径都报**绝对字节**；
  /// [cancelled] 返回 true 时立刻中止（抛 [_Cancelled]，调用方与失败区分开）。
  static Future<String> ensureInstalled({
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final existing = await installedDir();
    if (existing != null) return existing;

    // 包内资产探测：资产键不存在时 rootBundle.load 走 manifest 判断**快速
    // 失败**（不会真读 239MB），所以直接 try 即可，无需额外存在性 API。
    ByteData? onnx;
    try {
      onnx = await rootBundle.load('$_bundledPrefix/model.int8.onnx');
    } catch (_) {
      onnx = null; // 包里没有 → 下面走下载兜底
    }
    if (onnx != null) {
      return _installFromBundle(onnx,
          onProgress: onProgress, cancelled: cancelled);
    }
    return ensureDownloaded(onProgress: onProgress, cancelled: cancelled);
  }

  /// 把包内资产拷进应用目录（②级解析）。model.onnx 分 1MB 块写（平滑进度 +
  /// 可取消 + 取消时清残file），tokens.txt 一次写完；**大小 + sha256 双重
  /// 校验**——sha256 抓「大小对内容烂」的写坏文件（并发写花/磁盘问题），
  /// 抓不到就删掉抛错，用户重试即从资产重拷。
  static Future<String> _installFromBundle(
    ByteData onnx, {
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final root = await _rootDir();
    if (root == null) {
      throw Exception('voice transcript: unsupported platform');
    }
    await root.create(recursive: true);

    final model = _files.first;
    final tokens = _files.last;
    final total = model.size + tokens.size;
    final bytes = onnx.buffer.asUint8List(onnx.offsetInBytes, onnx.lengthInBytes);
    if (bytes.length != model.size) {
      throw Exception('bundled model size mismatch '
          '(${bytes.length} != ${model.size})');
    }
    final dest = File(p.join(root.path, model.name));
    final sink = dest.openWrite();
    try {
      const chunkSize = 1 << 20; // 1MB 一块：进度平滑，拷贝开销可忽略
      for (var off = 0; off < bytes.length; off += chunkSize) {
        if (cancelled?.call() ?? false) throw _Cancelled();
        sink.add(bytes.sublist(off, math.min(off + chunkSize, bytes.length)));
        onProgress?.call(math.min(off + chunkSize, bytes.length), total);
      }
      await sink.flush();
    } catch (_) {
      await sink.close().catchError((_) {});
      if (dest.existsSync()) dest.deleteSync(); // 取消/失败：清残file
      rethrow;
    }
    await sink.close();

    // 落盘后校验 sha256（不只是大小）：写坏/磁盘问题的文件在这里发现——
    // 2026-10-12 StatefulBuilder 重建导致多路并发写，曾把同一文件写花
    // （大小对、内容烂），只有哈希抓得到。不过则删掉抛错，用户重试即重拷。
    if (await _fileSha256(dest) != model.sha256) {
      if (dest.existsSync()) dest.deleteSync();
      throw Exception('bundled model integrity mismatch after copy');
    }

    final tokensData = await rootBundle.load('$_bundledPrefix/${tokens.name}');
    final tokensDest = File(p.join(root.path, tokens.name));
    await tokensDest.writeAsBytes(
        tokensData.buffer
            .asUint8List(tokensData.offsetInBytes, tokensData.lengthInBytes),
        flush: true);
    if (tokensDest.lengthSync() != tokens.size) {
      tokensDest.deleteSync();
      throw Exception('bundled tokens size mismatch');
    }

    File(p.join(root.path, '.ok'))
        .writeAsStringSync(DateTime.now().toIso8601String());
    onProgress?.call(total, total);
    return root.path;
  }

  /// 下载全部缺失文件（已齐全 → 直接返回目录）。兜底路径：仅当包里没有
  /// 模型资产时才会走到（dev 构建没跑 scripts/fetchVoiceModel.sh）。
  static Future<String> ensureDownloaded({
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final existing = await installedDir();
    if (existing != null) return existing;
    final root = await _rootDir();
    if (root == null) {
      throw Exception('voice transcript: unsupported platform');
    }
    await root.create(recursive: true);

    // 已完成文件的字节数（进度条基数：只加"当前文件"的实时进度）
    var baseDone = 0;
    for (final f in _files) {
      final dest = File(p.join(root.path, f.name));
      final part = File(p.join(root.path, '${f.name}.part'));
      if (dest.existsSync() && dest.lengthSync() == f.size) {
        baseDone += f.size;
        continue;
      }

      Object? lastError;
      for (final host in const ['https://hf-mirror.com', 'https://huggingface.co']) {
        try {
          await _downloadOne(
            host: host,
            repo: _repo,
            file: f,
            dest: dest,
            part: part,
            baseDone: baseDone,
            onProgress: onProgress,
            cancelled: cancelled,
          );
          lastError = null;
          break;
        } on _Cancelled {
          rethrow; // 用户主动取消：不是"这个源失败"，绝不能换源续跑
        } catch (e) {
          lastError = e;
          // 换主机前清 .part：不同主机的 Range 偏移不保证一致，续传会拼坏文件
          if (part.existsSync()) part.deleteSync();
        }
      }
      if (lastError != null) throw lastError;
      baseDone += f.size;
    }
    File(p.join(root.path, '.ok')).writeAsStringSync(
        DateTime.now().toIso8601String());
    return root.path;
  }

  static Future<void> _downloadOne({
    required String host,
    required String repo,
    required ({String name, int size, String sha256}) file,
    required File dest,
    required File part,
    required int baseDone,
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final resume = part.existsSync() ? part.lengthSync() : 0;
    final client = http.Client();
    // crypto 3.x 当前版本不导出 DigestSink，手写一个最小字节汇收集分块摘要
    final digestOut = <crypto.Digest>[];
    final hash = crypto.sha256.startChunkedConversion(
        _DigestCollector(digestOut));
    var received = resume;
    IOSink? sink;
    try {
      final req = http.Request('GET',
          Uri.parse('$host/$repo/resolve/main/${file.name}'));
      if (resume > 0) req.headers['range'] = 'bytes=$resume-';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw Exception('$host -> HTTP ${res.statusCode}');
      }
      // 206 = 续传生效（追加）；200 = 源不支持 Range（截断重下）
      final appending = resume > 0 && res.statusCode == 206;
      received = appending ? resume : 0;
      sink = part.openWrite(mode: appending ? FileMode.append : FileMode.write);
      onProgress?.call(baseDone + received, totalBytes);

      // 单块等待超过 2 分钟视为连接僵死（流 gap 超时 → 换源）
      final stream = res.stream.timeout(const Duration(seconds: 120));
      await for (final chunk in stream) {
        if (cancelled?.call() ?? false) throw _Cancelled();
        sink.add(chunk);
        hash.add(chunk);
        received += chunk.length;
        onProgress?.call(baseDone + received, totalBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      hash.close(); // 摘要经外层汇送达 digestOut
      final digest = digestOut.single;
      if (received != file.size || digest.toString() != file.sha256) {
        if (part.existsSync()) part.deleteSync();
        throw Exception('$host/${file.name} integrity mismatch '
            '($received/${digest.toString().substring(0, 12)}…)');
      }
      part.renameSync(dest.path);
    } catch (e) {
      await sink?.flush().catchError((_) {});
      await sink?.close().catchError((_) {});
      rethrow;
    } finally {
      client.close();
    }
  }
}

/// 用户主动取消下载（区别于网络失败，不触发换源）。
class _Cancelled implements Exception {}

/// 文件内容 sha256（流式，不把 239MB 读进内存；拷贝落盘校验用）。
Future<String> _fileSha256(File f) async {
  final out = <crypto.Digest>[];
  final hash = crypto.sha256.startChunkedConversion(_DigestCollector(out));
  await for (final chunk in f.openRead()) {
    hash.add(chunk);
  }
  hash.close(); // 摘要经外层汇送达 out
  return out.single.toString();
}

/// 最小摘要汇：chunked conversion 的外层汇——close() 时 sha256 把最终
/// Digest 送进来。crypto 3.x 当前版本不导出 DigestSink，用它顶替。
class _DigestCollector implements Sink<crypto.Digest> {
  _DigestCollector(this.out);

  final List<crypto.Digest> out;

  @override
  void add(crypto.Digest digest) => out.add(digest);

  @override
  void close() {}
}
