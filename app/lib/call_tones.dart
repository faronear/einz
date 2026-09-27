import 'dart:math';

import 'package:flutter/foundation.dart';

/// 语音通话的提示音（**程序生成 WAV**，不依赖任何素材文件）。
///
/// 为什么自己合成而不是打包素材：只有两声、都是纯音/简单音序，写个正弦发生器几十行
/// 就够了，省掉二进制资源（多两个音频文件还要管体积、多平台资源注册）。
///
/// 两端的音**刻意不同**（老板 2026-09-26）：
/// - 主叫听**回铃音**（嘀—… 嘀—…）：表示"已经拨出、在等对方接"；
/// - 被叫听**来电铃声**（叮铃铃）：表示"有人打给你，快接"。
/// 听声就能分辨自己在哪一端，不用看屏幕。
///
/// 只 import `foundation.dart` 拿 [Uint8List]——`dart:typeddata` 在本项目的分析
/// 环境里解析不到（其它 Dart 文件也都是这么间接取 Uint8List 的），所以 WAV 头
/// 手工按小端写字节，不用 `ByteData`/`Endian`。
class CallTones {
  CallTones._();

  static const int _sampleRate = 8000; // 8kHz：纯音够用，数据量小

  static Uint8List? _ringbackCache;
  static Uint8List? _ringtoneCache;

  /// 主叫侧：回铃音。450Hz，**响 1 秒、停 4 秒**（一回 5 秒循环）。
  static Uint8List ringback() => _ringbackCache ??= _encode(_synth(<_Tone>[
        const _Tone(frequency: 450, seconds: 1),
        const _Tone(frequency: 0, seconds: 4), // 0Hz = 静音段
      ]));

  /// 被叫侧：来电铃声。三个上行音一组、组间留白（叮铃铃 —— 叮铃铃 ——）。
  static Uint8List ringtone() => _ringtoneCache ??= _encode(_synth(<_Tone>[
        const _Tone(frequency: 880, seconds: 0.18),
        const _Tone(frequency: 988, seconds: 0.18),
        const _Tone(frequency: 1175, seconds: 0.18),
        const _Tone(frequency: 0, seconds: 0.12),
        const _Tone(frequency: 880, seconds: 0.18),
        const _Tone(frequency: 988, seconds: 0.18),
        const _Tone(frequency: 1175, seconds: 0.18),
        const _Tone(frequency: 0, seconds: 0.9),
      ]));

  /// 按音序合成采样点（-1..1）。每个音首尾各 8ms 淡入淡出，避免"咔哒"爆音。
  static List<double> _synth(List<_Tone> sequence) {
    const fadeSeconds = 0.008;
    final out = <double>[];
    for (final tone in sequence) {
      final count = (tone.seconds * _sampleRate).round();
      var fade = (fadeSeconds * _sampleRate).round();
      if (fade > count ~/ 2) fade = count ~/ 2;
      for (var i = 0; i < count; i++) {
        var amplitude = 1.0;
        if (fade > 0 && i < fade) amplitude = i / fade;
        if (fade > 0 && i > count - 1 - fade) amplitude = (count - 1 - i) / fade;
        final value = tone.frequency <= 0
            ? 0.0
            : sin(2 * pi * tone.frequency * i / _sampleRate);
        // 幅度 0.35：提示音不该太吵
        out.add(value * amplitude * 0.35);
      }
    }
    return out;
  }

  /// 采样点 → 16bit 单声道 WAV（44 字节头 + PCM）。
  static Uint8List _encode(List<double> samples) {
    final dataBytes = samples.length * 2;
    final bytes = Uint8List(44 + dataBytes);

    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        bytes[offset + i] = text.codeUnitAt(i);
      }
    }

    void u32(int offset, int value) {
      for (var i = 0; i < 4; i++) {
        bytes[offset + i] = (value >> (8 * i)) & 0xFF; // 小端
      }
    }

    void u16(int offset, int value) {
      bytes[offset] = value & 0xFF;
      bytes[offset + 1] = (value >> 8) & 0xFF;
    }

    ascii(0, 'RIFF');
    u32(4, 36 + dataBytes);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    u32(16, 16); // fmt 子块长度
    u16(20, 1); // PCM
    u16(22, 1); // 单声道
    u32(24, _sampleRate);
    u32(28, _sampleRate * 2); // 字节率 = 采样率 × 通道数 × 位深/8
    u16(32, 2); // 块对齐
    u16(34, 16); // 位深
    ascii(36, 'data');
    u32(40, dataBytes);

    var offset = 44;
    for (final sample in samples) {
      final clamped = (sample * 32767).clamp(-32768.0, 32767.0).round();
      // 16bit 有符号、小端：先写低字节
      bytes[offset] = clamped & 0xFF;
      bytes[offset + 1] = (clamped >> 8) & 0xFF;
      offset += 2;
    }
    return bytes;
  }
}

class _Tone {
  const _Tone({required this.frequency, required this.seconds});

  /// 频率（Hz）；0 = 静音段。
  final double frequency;
  final double seconds;
}
