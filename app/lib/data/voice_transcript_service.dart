import 'dart:async';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'local_database.dart';
import 'voice_transcript_model.dart';

/// 语音消息本地转写服务（`aimemo/voiceTranscript.zhcn.md` §6/§7/§9）。
///
/// 定位：**纯本地派生缓存**——各端各自把已解密的明文音频转写成文字，结果只进
/// 本地 `local_voice_transcripts` 表；不产生任何网络流量、服务端不可见。
///
/// - 转写在**后台 isolate 串行**执行（CPU 密集，不抢 UI 线程、不并发抢 CPU）。
/// - 模型未就绪（未下载/未打包）→ 行置 `unavailable`，UI 提供手动入口不露错误。
/// - 失败重试上限 [maxRetries] 次后置 `failed`。
/// - 模型版本或音频 sha256 与行内记录不一致 → 置 `stale`（可惰性重转）。
class VoiceTranscriptService {
  VoiceTranscriptService(this._db, {this.modelDir});

  final LocalDatabase _db;

  /// 模型目录（含 model.int8.onnx + tokens.txt）。
  /// null = 走 [VoiceTranscriptModel.installedDir]（未就绪 → 行置
  /// unavailable，用户点手动入口时由 ChatPage 调 ensureInstalled 就地
  /// 安装——包内资产拷贝优先、下载兜底，见 §11）。显式传入仅供测试注入。
  final String? modelDir;

  /// 当前模型版本标识（进 `model_version` 列，判定 stale 的开关）。
  /// 单一事实源在下载器（目录名与版本同源演进），这里只引用。
  static const String kModelId = 'sense-voice-small';
  static const String kModelVersion = VoiceTranscriptModel.kModelVersion;

  /// 失败重试上限（§9：建议 2 次）。
  static const int maxRetries = 2;

  /// 串行队列：isolate 池只留一个在跑（§6：避免并发抢 CPU）。
  Future<void>? _tail;
  sherpa.OfflineRecognizer? _recognizer;

  /// 解析可用的模型目录：显式注入优先；否则查下载器安装状态
  /// （文件 + .ok 标记齐全才算——下载中断的目录不算就绪）。
  Future<String?> _resolveModelDir() async =>
      modelDir ?? await VoiceTranscriptModel.installedDir();

  /// 模型是否就绪（决定「自动转写」还是「unavailable」）。异步：查安装状态。
  Future<bool> get modelReady async =>
      await _resolveModelDir() != null;

  /// 入队一条语音消息的转写（收到且音频已解密后调用；幂等——已有 done 行跳过）。
  ///
  /// [plainPath] = 解密后的**明文音频**本地路径（wav/16kHz 单声道最佳，见 §8）；
  /// [cipherSha256] = 音频**密文** sha256（音频变化 → 旧转写失效的判据）。
  void enqueue({
    required String messageId,
    required String plainPath,
    required String cipherSha256,
  }) {
    _tail = _tail?.catchError((_) {}) ?? Future.value();
    _tail = _tail!.then((_) => _processOne(messageId, plainPath, cipherSha256));
  }

  Future<void> _processOne(
      String messageId, String plainPath, String cipherSha256) async {
    final existing =
        await (_db.select(_db.localVoiceTranscripts)
              ..where((t) => t.messageId.equals(messageId)))
            .getSingleOrNull();
    // 已有**当前模型版本**的有效结果 → 不重算（幂等；stale 的留给手动入口）
    if (existing != null &&
        existing.status == 'done' &&
        existing.modelVersion == kModelVersion &&
        existing.audioSha256 == cipherSha256) {
      return;
    }
    final dir = await _resolveModelDir();
    if (dir == null) {
      await _upsert(messageId, status: 'unavailable', cipherSha256: cipherSha256);
      return;
    }
    await _upsert(messageId, status: 'pending', cipherSha256: cipherSha256);
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final r = await _runIsolate(plainPath, dir);
        await _upsert(messageId,
            status: 'done',
            text: r.$1,
            language: r.$2,
            cipherSha256: cipherSha256);
        return;
      } catch (_) {
        if (attempt > maxRetries) {
          await _upsert(messageId, status: 'failed', cipherSha256: cipherSha256);
          return;
        }
      }
    }
  }

  /// 后台 isolate 跑一次 ASR（返回 (text, language)）。
  /// 只把顶层函数 + 纯值参数送进 isolate——闭包捕获 `this` 会把 drift 句柄
  /// （不可跨 isolate）一起带上导致运行时崩溃；recognizer 在 isolate 内新建，
  /// sherpa-onnx 的 FFI 句柄本就不能跨 isolate 传递。
  Future<(String, String)> _runIsolate(String plainPath, String modelDir) {
    return Isolate.run(
        () => transcribeWavFile(path: plainPath, modelDir: modelDir));
  }

  /// isolate 顶层入口：加载模型 → 转写一个 wav 文件 → (text, language)。
  /// 每次调用独立建 recognizer（isolate 间无共享；文件级成本可接受，60s 上限的
  /// 语音消息转写本身是秒级，模型加载占大头——Phase 0 真机实测后再决定是否
  /// 改常驻 isolate 池）。
  static (String, String) transcribeWavFile({
    required String path,
    required String modelDir,
  }) {
    final rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: '$modelDir/model.int8.onnx',
          // 留空 = 自动检测语言（中/粤/英/日/韩，§5）
          language: '',
          useInverseTextNormalization: true, // 数字规整（"三个"→"3 个"）
        ),
        tokens: '$modelDir/tokens.txt',
        modelType: 'sense-voice',
        numThreads: 2,
      ),
    ));
    final stream = rec.createStream();
    try {
      // readWave 支持 16bit PCM wav；ASR 期望 16kHz 单声道（§8 走 wav 录音路径）
      final wave = sherpa.readWave(path);
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      rec.decode(stream);
      final result = rec.getResult(stream);
      // SenseVoice 结果带情感/事件标签（§5），text 已剥离标签只留正文
      return (result.text.trim(), result.lang);
    } finally {
      stream.free();
      rec.free();
    }
  }

  Future<void> _upsert(
    String messageId, {
    required String status,
    String text = '',
    String language = '',
    required String cipherSha256,
  }) async {
    await _db.into(_db.localVoiceTranscripts).insertOnConflictUpdate(
          LocalVoiceTranscriptsCompanion.insert(
            messageId: messageId,
            transcript: Value(text),
            modelId: const Value(kModelId),
            modelVersion: const Value(kModelVersion),
            audioSha256: Value(cipherSha256),
            language: Value(language),
            status: Value(status),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  /// 释放原生句柄（app 退出时调用；不释放也能被进程回收，但显式更干净）。
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
  }
}
