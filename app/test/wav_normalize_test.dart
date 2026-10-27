// 回归测试：wav 容器规范化（2026-10-23 macOS 实测事故）——record 插件在 macOS
// 上把标准 PCM16 录音写成 WAVE_FORMAT_EXTENSIBLE（tag=0xFFFE）容器，sherpa-onnx
// 的 wave-reader 明确不支持（"We don't support WAVE_FORMAT_EXTENSIBLE files."），
// 必须转成标准 44 字节头 PCM 才能喂本地转写。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/voice_transcript_service.dart';

/// macOS 录音器实测形态：JUNK + 40 字节 extensible fmt + FLLR + data。
/// 数据是标准 16bit 交错 PCM（[payload] 的每个 int 当一个采样点写）。
Uint8List makeExtensibleWav(List<int> payload, {int subFormat = 1}) {
  const junk = 28;
  const fllr = 4;
  const fmtSize = 40;
  final data = Uint8List.fromList(payload);
  final total = 12 + 8 + junk + 8 + fmtSize + 8 + fllr + 8 + data.length;
  final b = Uint8List(total);
  final bd = ByteData.sublistView(b);
  void ascii(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b[at + i] = s.codeUnitAt(i);
    }
  }
  ascii(0, 'RIFF');
  bd.setUint32(4, total - 8, Endian.little);
  ascii(8, 'WAVE');
  var o = 12;
  ascii(o, 'JUNK');
  bd.setUint32(o + 4, junk, Endian.little);
  o += 8 + junk;
  ascii(o, 'fmt ');
  bd.setUint32(o + 4, fmtSize, Endian.little);
  bd.setUint16(o + 8, 0xfffe, Endian.little); // WAVE_FORMAT_EXTENSIBLE
  bd.setUint16(o + 10, 1, Endian.little); // mono
  bd.setUint32(o + 12, 16000, Endian.little); // 16kHz
  bd.setUint32(o + 16, 32000, Endian.little); // byte rate
  bd.setUint16(o + 20, 2, Endian.little); // block align
  bd.setUint16(o + 22, 16, Endian.little); // 16bit
  bd.setUint16(o + 24, 22, Endian.little); // cbSize
  bd.setUint16(o + 26, 16, Endian.little); // valid bits
  bd.setUint32(o + 28, 0, Endian.little); // channel mask
  bd.setUint16(o + 32, subFormat, Endian.little); // GUID 头两位：1=PCM，3=float
  o += 8 + fmtSize;
  ascii(o, 'FLLR');
  bd.setUint32(o + 4, fllr, Endian.little);
  o += 8 + fllr;
  ascii(o, 'data');
  bd.setUint32(o + 4, data.length, Endian.little);
  b.setRange(o + 8, o + 8 + data.length, data);
  return b;
}

/// 标准 16bit PCM wav（tag=1，44 字节头）。
Uint8List makePlainWav(List<int> payload) {
  final data = Uint8List.fromList(payload);
  final b = Uint8List(44 + data.length);
  final bd = ByteData.sublistView(b);
  void ascii(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b[at + i] = s.codeUnitAt(i);
    }
  }
  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + data.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, 16000, Endian.little);
  bd.setUint32(28, 32000, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, data.length, Endian.little);
  b.setRange(44, 44 + data.length, data);
  return b;
}


/// 通用 extensible wav 构造（JUNK + 40 字节 fmt + FLLR + data）：[subFormat] 为
/// 子格式 GUID 头两位（1=PCM / 3=IEEE float），[bits] 16=int16 / 32=float32。
Uint8List makeExtensibleWav2({
  required int subFormat,
  required int bits,
  required int rate,
  required List<double> samples,
}) {
  const junk = 28;
  const fllr = 4;
  const fmtSize = 40;
  final isFloat = bits == 32;
  final data = Uint8List(samples.length * (isFloat ? 4 : 2));
  final dd = ByteData.sublistView(data);
  for (var i = 0; i < samples.length; i++) {
    if (isFloat) {
      dd.setFloat32(i * 4, samples[i], Endian.little);
    } else {
      dd.setInt16(i * 2, samples[i].round().clamp(-32768, 32767), Endian.little);
    }
  }
  final total = 12 + 8 + junk + 8 + fmtSize + 8 + fllr + 8 + data.length;
  final b = Uint8List(total);
  final bd = ByteData.sublistView(b);
  void ascii(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b[at + i] = s.codeUnitAt(i);
    }
  }
  ascii(0, 'RIFF');
  bd.setUint32(4, total - 8, Endian.little);
  ascii(8, 'WAVE');
  var o = 12;
  ascii(o, 'JUNK');
  bd.setUint32(o + 4, junk, Endian.little);
  o += 8 + junk;
  ascii(o, 'fmt ');
  bd.setUint32(o + 4, fmtSize, Endian.little);
  bd.setUint16(o + 8, 0xfffe, Endian.little);
  bd.setUint16(o + 10, 1, Endian.little); // mono
  bd.setUint32(o + 12, rate, Endian.little);
  bd.setUint32(o + 16, rate * (bits ~/ 8), Endian.little);
  bd.setUint16(o + 20, bits ~/ 8, Endian.little);
  bd.setUint16(o + 22, bits, Endian.little);
  bd.setUint16(o + 24, 22, Endian.little);
  bd.setUint16(o + 26, bits, Endian.little);
  bd.setUint32(o + 28, 0, Endian.little);
  bd.setUint16(o + 32, subFormat, Endian.little);
  o += 8 + fmtSize;
  ascii(o, 'FLLR');
  bd.setUint32(o + 4, fllr, Endian.little);
  o += 8 + fllr;
  ascii(o, 'data');
  bd.setUint32(o + 4, data.length, Endian.little);
  b.setRange(o + 8, o + 8 + data.length, data);
  return b;
}

void main() {
  final payload = List<int>.generate(320, (i) => i % 251); // 320 字节"采样数据"

  test('extensible PCM → 标准 44 字节头，数据一个字节不改', () {
    final ext = makeExtensibleWav(payload);
    final out = VoiceTranscriptService.normalizeWavBytes(ext);
    expect(identical(out, ext), isFalse, reason: 'extensible 必须被重写');
    expect(out.length, 44 + payload.length, reason: '剥掉 JUNK/FLLR 后只剩标准头+data');
    final od = ByteData.sublistView(out);
    expect(od.getUint16(20, Endian.little), 1, reason: 'tag 应为 1（PCM）');
    expect(od.getUint32(4, Endian.little), 36 + payload.length, reason: 'RIFF size');
    expect(od.getUint16(22, Endian.little), 1, reason: 'mono 保留');
    expect(od.getUint32(24, Endian.little), 16000, reason: '采样率保留');
    expect(od.getUint32(28, Endian.little), 32000, reason: 'byteRate');
    expect(od.getUint16(32, Endian.little), 2, reason: 'blockAlign');
    expect(od.getUint16(34, Endian.little), 16, reason: '16bit 保留');
    expect(od.getUint32(40, Endian.little), payload.length, reason: 'data size');
    expect(out.sublist(44), payload, reason: '数据原样，一个采样点不动');
  });

  test('幂等：规范化两次结果一致', () {
    final once = VoiceTranscriptService.normalizeWavBytes(makeExtensibleWav(payload));
    final twice = VoiceTranscriptService.normalizeWavBytes(once);
    expect(identical(twice, once), isTrue, reason: '标准头第二次应零成本原样返回');
  });

  test('标准 PCM wav 原样返回（同一实例）', () {
    final plain = makePlainWav(payload);
    expect(identical(VoiceTranscriptService.normalizeWavBytes(plain), plain), isTrue);
  });

  test('float 子格式（GUID=3）不碰——交给上游拒绝，不静默乱转', () {
    final floatExt = makeExtensibleWav(payload, subFormat: 3);
    expect(identical(VoiceTranscriptService.normalizeWavBytes(floatExt), floatExt), isTrue);
  });

  test('垃圾/过短输入原样返回', () {
    final junk = Uint8List.fromList('not a wav at all..........'.codeUnits);
    expect(identical(VoiceTranscriptService.normalizeWavBytes(junk), junk), isTrue);
    final short = Uint8List(10);
    expect(identical(VoiceTranscriptService.normalizeWavBytes(short), short), isTrue);
  });


  test('extensible float32 @44.1kHz → 重采样 + 转 int16 标准 PCM（录音器回落形态）', () {
    // 复刻 2026-10-23 实测形态：录音器没拿到 16kHz 时 AVCaptureAudioFileOutput
    // 写设备原生格式——44.1kHz/32bit float 的 extensible。常数 0.5 信号重采样后
    // 每个目标点仍应是 0.5 → int16 16384。
    final samples = List<double>.filled(4410, 0.5); // 0.1s @44.1k
    final ext = makeExtensibleWav2(
        subFormat: 3, bits: 32, rate: 44100, samples: samples);
    final out = VoiceTranscriptService.normalizeWavBytes(ext);
    final od = ByteData.sublistView(out);
    expect(od.getUint16(20, Endian.little), 1, reason: 'tag 应为 1');
    expect(od.getUint32(24, Endian.little), 16000, reason: '重采样到 16kHz');
    expect(od.getUint16(34, Endian.little), 16, reason: '16bit');
    final outCount = od.getUint32(40, Endian.little) ~/ 2;
    expect(outCount, 1600, reason: '0.1s 音频 → 1600 个 16k 采样点');
    for (var i = 0; i < outCount; i++) {
      expect(od.getInt16(44 + i * 2, Endian.little), 16384,
          reason: '0.5 × 32767 四舍五入');
    }
  });

  test('extensible float32 @16kHz → 1:1 转 int16（不重采样，值精确）', () {
    final ext = makeExtensibleWav2(
        subFormat: 3, bits: 32, rate: 16000,
        samples: [0.0, 1.0, -1.0, 0.5]);
    final out = VoiceTranscriptService.normalizeWavBytes(ext);
    expect(out.length, 44 + 8);
    final od = ByteData.sublistView(out);
    expect([
      od.getInt16(44, Endian.little),
      od.getInt16(46, Endian.little),
      od.getInt16(48, Endian.little),
      od.getInt16(50, Endian.little),
    ], [0, 32767, -32767, 16384]);
  });

  test('extensible float32 @44.1kHz 斜坡信号：线性插值保形（端点与中段）', () {
    // 0→1 斜坡：线性插值对斜坡是精确的——out[i] ≈ (i×step)/N
    const n = 4410;
    final samples = List<double>.generate(n, (i) => i / (n - 1));
    final ext = makeExtensibleWav2(
        subFormat: 3, bits: 32, rate: 44100, samples: samples);
    final out = VoiceTranscriptService.normalizeWavBytes(ext);
    final od = ByteData.sublistView(out);
    final outCount = od.getUint32(40, Endian.little) ~/ 2;
    expect(od.getInt16(44, Endian.little), 0, reason: '起点 0');
    // 末点：pos=(outCount-1)×2.75625 → 值 ≈ 该位置/4409
    final lastPos = (outCount - 1) * (44100 / 16000);
    expect(od.getInt16(44 + (outCount - 1) * 2, Endian.little),
        closeTo((lastPos / (n - 1)) * 32767, 2));
    // 全程单调不减（插值不制造回绕）
    var prev = -32769;
    for (var i = 0; i < outCount; i++) {
      final v = od.getInt16(44 + i * 2, Endian.little);
      expect(v, greaterThanOrEqualTo(prev));
      prev = v;
    }
  });

  test('extensible PCM16 @44.1kHz → 重采样到 16k（常数信号保幅）', () {
    final ext = makeExtensibleWav2(
        subFormat: 1, bits: 16, rate: 44100,
        samples: List<double>.filled(4410, 1000));
    final out = VoiceTranscriptService.normalizeWavBytes(ext);
    final od = ByteData.sublistView(out);
    final outCount = od.getUint32(40, Endian.little) ~/ 2;
    expect(outCount, 1600);
    for (var i = 0; i < outCount; i++) {
      expect(od.getInt16(44 + i * 2, Endian.little), 1000);
    }
  });

  test('不支持的形态仍原样返回（多声道 float / 24bit）', () {
    // 多声道：makeExtensibleWav2 只写 mono，这里手工把 channels 改成 2 验证拒绝
    final ext = makeExtensibleWav2(
        subFormat: 3, bits: 32, rate: 16000, samples: [0.5, 0.5]);
    ByteData.sublistView(ext).setUint16(12 + 8 + 28 + 10, 2, Endian.little);
    expect(identical(VoiceTranscriptService.normalizeWavBytes(ext), ext), isTrue);
    // 24bit（既非 16 也非 32）：不猜
    final ext24 = makeExtensibleWav2(
        subFormat: 1, bits: 16, rate: 16000, samples: [1, 1]);
    ByteData.sublistView(ext24).setUint16(12 + 8 + 28 + 22, 24, Endian.little);
    expect(
        identical(VoiceTranscriptService.normalizeWavBytes(ext24), ext24), isTrue);
  });

  test('文件版：就地规范化 + 幂等', () {
    final dir = Directory.systemTemp.createTempSync('einz-wav-norm-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/voice.wav');
    f.writeAsBytesSync(makeExtensibleWav(payload));
    VoiceTranscriptService.normalizeWavFile(f.path);
    final after = f.readAsBytesSync();
    expect(ByteData.sublistView(after).getUint16(20, Endian.little), 1);
    expect(after.length, 44 + payload.length);
    expect(after.sublist(44), payload);
    // 再来一次：文件字节不变（幂等），也不留 .norm 残file
    VoiceTranscriptService.normalizeWavFile(f.path);
    expect(f.readAsBytesSync(), after);
    expect(File('${f.path}.norm').existsSync(), isFalse);
  });
}
