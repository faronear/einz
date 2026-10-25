import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'local_database.dart';
import 'voice_transcript_model.dart';

/// 语音消息本地转写服务（`aimemo/20261009_voiceTranscript.zhcn.md` §6/§7/§9）。
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

  /// 转写一个**本地明文 wav 文件**（不落库、无 messageId 语义）——供录音预览态
  /// 的即时转写用（老板 2026-10-25：预览态长按波形图弹窗转写，Apply 后文字
  /// 追加进输入框、原录音保留）。返回 (text, language)。
  ///
  /// 与 [_processOne] 共用串行队列（_tail）与 isolate 跑法（不并发抢 CPU）；
  /// 模型未就绪抛 [StateError]（调用方应先 ensureInstalled）；文件头不合格抛
  /// [ArgumentError]（与消息链路同口径：先拦下，绝不进 sherpa 原生层）。
  Future<(String, String)> transcribeFile(String plainPath) {
    final previous = _tail?.catchError((_) {}) ?? Future.value();
    final result = previous.then((_) => _transcribeFileNow(plainPath));
    // 队列链只承接 void：把本次的结果/异常都咽掉——异常已透传给调用方的
    // result（对话框照常显示失败），不会变成未处理的异步错误
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<(String, String)> _transcribeFileNow(String plainPath) async {
    final dir = await _resolveModelDir();
    if (dir == null) {
      throw StateError('voice transcript model not installed');
    }
    // 预览态录音在 _stopVoice 时已规范化过；这里再兜底一次（幂等快路径）
    normalizeWavFile(plainPath);
    return _runIsolate(plainPath, dir);
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
    // 规范化上线前录的老消息可能是 extensible 容器（macOS 录音器形态）：
    // sherpa wave-reader 明确不支持 0xFFFE——喂 isolate 前先转标准 PCM16 头
    normalizeWavFile(plainPath);
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
    // 喂给 sherpa 前先验 wav 头（见 [validateWavHeader]）——原生层除零
    // SIGFPE 直接杀进程，Dart catch 拦不住，必须在进原生前拦下。
    validateWavHeader(path);
    // 包要求**每个**用到 sherpa 的 isolate 先 initBindings 一次：缺了绑定表
    // 全是 null → 建 recognizer 即抛 "Please initialize sherpa-onnx first"
    // → 重试耗尽落 failed（老板 2026-10-22 实测"转写失败"的根因之一）。
    // macOS/iOS 走 DynamicLibrary.process()（pod 链入进程即可解析）。
    sherpa.initBindings();
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

  /// 转写前校验 wav 文件头：RIFF/WAVE 标记 + `data` 块存在且非空。
  ///
  /// 不合格（录音中断落下的空壳、data=0 等）直接抛异常 → 由
  /// [_processOne] 的重试耗尽落 `failed`，**绝不进 sherpa 原生层**：
  /// sherpa-onnx 对 0 采样数据会在原生代码里除零 SIGFPE，杀掉整个
  /// 进程（Dart catch 拦不住，2026-10-23 模拟器「进聊天页必崩」的根因——
  /// tmp 里一条断录的 einz_voice_*.wav，data 块 0 字节，每次进页自动
  /// 补转写即崩即重试成死循环）。
  ///
  /// 块头逐个增量读（不开整个文件进内存）；跳过 JUNK/FLLR 等填充块
  /// （iOS 录音器会插），遍历规则与 sherpa wave-reader 一致——但它不查
  /// data 是否为空，那正是 SIGFPE 的来源。
  static void validateWavHeader(String path) {
    final f = File(path).openSync();
    try {
      final len = f.lengthSync();
      final head = f.readSync(12);
      // 'RIFF'....'WAVE'
      if (head.length < 12 ||
          head[0] != 0x52 || head[1] != 0x49 ||
          head[2] != 0x46 || head[3] != 0x46 ||
          head[8] != 0x57 || head[9] != 0x41 ||
          head[10] != 0x56 || head[11] != 0x45) {
        throw ArgumentError('not a RIFF/WAVE file: $path (${len}B)');
      }
      var pos = 12;
      final idBuf = List<int>.filled(4, 0);
      while (pos + 8 <= len) {
        f.setPositionSync(pos);
        f.readIntoSync(idBuf, 0, 4);
        final size = ByteData.sublistView(f.readSync(4))
            .getUint32(0, Endian.little);
        if (idBuf[0] == 0x64 && idBuf[1] == 0x61 && // 'data'
            idBuf[2] == 0x74 && idBuf[3] == 0x61) {
          if (size == 0 || pos + 8 + size > len) {
            throw ArgumentError(
                'empty/truncated data chunk ($size B): $path');
          }
          return;
        }
        pos += 8 + size + (size & 1); // 块按 2 字节对齐
      }
      throw ArgumentError('no data chunk found: $path');
    } finally {
      f.closeSync();
    }
  }

  /// 转写链路的采样率约定（ sherpa sense-voice 与 whisper 都按 16kHz 口径，
  /// 20261009_voiceTranscript.zhcn.md §8）：规范化输出恒定 16kHz/16bit/mono PCM。
  static const int kTranscriptSampleRate = 16000;

  /// 把 wav 容器规范化成**标准 16kHz/16bit/mono PCM**（tag=1、44 字节头）；
  /// 无需改动的原样返回（同一实例，调用方可靠 [identical] 判断是否变过）。
  ///
  /// 为什么必须转：sherpa-onnx 的 wave-reader 明确不支持 extensible
  /// （"We don't support WAVE_FORMAT_EXTENSIBLE files."，上游源码可查），而
  /// macOS 录音器（record 插件的 AVCaptureAudioFileOutput）2026-10-23 实测会
  /// 把录音写成 extensible 容器（JUNK + 40 字节 fmt + FLLR + data）——直接喂
  /// 本地转写必失败；服务端旧代码同样只认 tag=1。
  ///
  /// 录音器实测会产出三种形态，分别处理：
  /// ① **16kHz/16bit PCM**（GUID=1，绝大多数）：只重写 44 字节标准头，数据
  ///    一个采样点不动（快路径）；
  /// ② **44.1kHz/32bit IEEE float**（GUID=3，录音器没拿到 16kHz 时的回落形态
  ///    ——2026-10-23 实测命中：拾音设备原生格式被 AVCaptureAudioFileOutput 原样
  ///    写出）：线性重采样到 16kHz + float→int16 量化；
  /// ③ **16bit PCM 但非 16kHz**：同样重采样。
  /// 其余形态（非 extensible 的 float、多声道、8/24bit 等）不猜——原样返回，
  /// 交给 validateWavHeader / 服务端拒绝，不静默"修"成别的东西。
  static Uint8List normalizeWavBytes(Uint8List bytes) {
    if (bytes.length < 44) return bytes;
    // RIFF/WAVE 快检（与 [validateWavHeader] 同口径）
    if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46 ||
        bytes[8] != 0x57 || bytes[9] != 0x41 || bytes[10] != 0x56 || bytes[11] != 0x45) {
      return bytes;
    }
    final bd = ByteData.sublistView(bytes);
    // 逐 chunk 找 fmt 与 data（容忍 JUNK/FLLR 填充块与乱序）
    var fmtStart = -1;
    var fmtSize = 0;
    var dataStart = -1;
    var dataSize = 0;
    var pos = 12;
    while (pos + 8 <= bytes.length) {
      final isFmt = bytes[pos] == 0x66 && bytes[pos + 1] == 0x6d && // 'fmt '
          bytes[pos + 2] == 0x74 && bytes[pos + 3] == 0x20;
      final isData = bytes[pos] == 0x64 && bytes[pos + 1] == 0x61 && // 'data'
          bytes[pos + 2] == 0x74 && bytes[pos + 3] == 0x61;
      final size = bd.getUint32(pos + 4, Endian.little);
      if (isFmt && fmtStart < 0) {
        fmtStart = pos;
        fmtSize = size;
      }
      if (isData && dataStart < 0) {
        dataStart = pos + 8;
        dataSize = size;
      }
      if (fmtStart >= 0 && dataStart >= 0) break;
      if (size == 0 && !isData) break; // 防畸形头死循环（同 validateWavHeader）
      pos += 8 + size + (size & 1); // 块按 2 字节对齐
    }
    if (fmtStart < 0 || dataStart < 0 || fmtSize < 16) return bytes;
    final tag = bd.getUint16(fmtStart + 8, Endian.little);
    final channels = bd.getUint16(fmtStart + 10, Endian.little);
    final rate = bd.getUint32(fmtStart + 12, Endian.little);
    final bits = bd.getUint16(fmtStart + 22, Endian.little);
    // extensible 才有子格式 GUID（fmt 40 字节）：头两位 1=PCM / 3=IEEE float
    var subFormat = 0;
    if (tag == 0xfffe) {
      if (fmtSize < 40 || fmtStart + 48 > bytes.length) return bytes;
      subFormat = bd.getUint16(fmtStart + 32, Endian.little);
    }
    final isInt16 = bits == 16 && (tag == 1 || subFormat == 1);
    final isFloat32 = bits == 32 && tag == 0xfffe && subFormat == 3;
    if (channels != 1 || rate == 0 || (!isInt16 && !isFloat32)) return bytes;
    final avail = bytes.length - dataStart;
    final srcLen = dataSize < avail ? dataSize : avail;

    // 写标准 44 字节头（tag=1 / mono / [rate] / 16bit）；两条路径共用
    void writeHeader(Uint8List out, int dataLen, int outRate) {
      final od = ByteData.sublistView(out);
      void ascii(int at, String s) {
        for (var i = 0; i < 4; i++) {
          out[at + i] = s.codeUnitAt(i);
        }
      }
      ascii(0, 'RIFF');
      od.setUint32(4, 36 + dataLen, Endian.little);
      ascii(8, 'WAVE');
      ascii(12, 'fmt ');
      od.setUint32(16, 16, Endian.little);
      od.setUint16(20, 1, Endian.little); // PCM
      od.setUint16(22, 1, Endian.little); // mono
      od.setUint32(24, outRate, Endian.little);
      od.setUint32(28, outRate * 2, Endian.little); // byte rate
      od.setUint16(32, 2, Endian.little); // block align
      od.setUint16(34, 16, Endian.little); // 16bit
      ascii(36, 'data');
      od.setUint32(40, dataLen, Endian.little);
    }

    // 快路径：16kHz/16bit——tag=1 零成本原样返回；extensible 只换头、数据不动
    if (isInt16 && rate == kTranscriptSampleRate) {
      if (tag == 1) return bytes;
      final out = Uint8List(44 + srcLen);
      writeHeader(out, srcLen, rate);
      out.setRange(44, 44 + srcLen, bytes, dataStart); // 数据原样，一个字节不改
      return out;
    }

    // 转换路径：float32（或非 16k 的 int16）→ 线性重采样到 16kHz + 量化 int16。
    // 线性插值对语音足够（whisper/sherpa 前端还会再处理），换来的好处是零依赖、
    // 无第三方重采样器的许可与体积风险。
    final bytesPerSample = isFloat32 ? 4 : 2;
    final srcCount = srcLen ~/ bytesPerSample;
    if (srcCount == 0) return bytes;
    final step = rate / kTranscriptSampleRate; // 源采样点 / 目标采样点
    final outCount = srcCount ~/ step;
    if (outCount == 0) return bytes;
    final out = Uint8List(44 + outCount * 2);
    writeHeader(out, outCount * 2, kTranscriptSampleRate);
    final od = ByteData.sublistView(out);
    for (var i = 0; i < outCount; i++) {
      final pos = i * step;
      final i0 = pos.floor();
      final i1 = i0 + 1 < srcCount ? i0 + 1 : i0;
      final frac = pos - i0;
      final double s0;
      final double s1;
      if (isFloat32) {
        s0 = bd.getFloat32(dataStart + i0 * 4, Endian.little);
        s1 = bd.getFloat32(dataStart + i1 * 4, Endian.little);
      } else {
        s0 = bd.getInt16(dataStart + i0 * 2, Endian.little) / 32768;
        s1 = bd.getInt16(dataStart + i1 * 2, Endian.little) / 32768;
      }
      final v = s0 + (s1 - s0) * frac; // 线性插值（i1==i0 时 frac 无关）
      // float 采集的故障帧会产出 NaN/Inf（实测命中：真实录音直接让 round() 抛
      // "Infinity or NaN toInt"）——按静音处理；先 clamp double 再 round，
      // 顺带防超大有限值溢出。
      final q =
          v.isFinite ? (v * 32767).clamp(-32768.0, 32767.0).round() : 0;
      od.setInt16(44 + i * 2, q, Endian.little);
    }
    return out;
  }

  /// 文件版 [normalizeWavBytes]：就地规范化（临时文件 + rename 原子替换，避免
  /// 并发读取撞上半个头）。未变（非 extensible / 解析不了）不动文件。
  static void normalizeWavFile(String path) {
    final f = File(path);
    if (!f.existsSync()) return;
    final bytes = f.readAsBytesSync();
    final out = normalizeWavBytes(bytes);
    if (identical(out, bytes)) return;
    final tmp = File('$path.norm');
    tmp.writeAsBytesSync(out);
    tmp.renameSync(path); // POSIX rename 原子替换
  }

  /// 文件是否含真实音频数据（录音侧发送/进预览前判定用）。
  /// 任何读不出来的情况（文件缺失/头损坏）都算无数据。
  static bool hasAudioData(String path) {
    try {
      validateWavHeader(path);
      return true;
    } catch (_) {
      return false;
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
