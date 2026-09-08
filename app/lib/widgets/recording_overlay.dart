import 'dart:async';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

/// 录音中页面中央遮罩：真实振幅驱动的波形条 + 录音时长 + 提示文案。
/// 振幅流由 ChatPage 在开始录音时提供（record 插件 onAmplitudeChanged），
/// 本组件自行订阅，随 _recording 状态卸载时自动取消订阅。
class RecordingOverlay extends StatefulWidget {
  const RecordingOverlay({
    super.key,
    required this.amplitudeStream,
    required this.hintText,
  });

  final Stream<Amplitude> amplitudeStream;

  /// 提示文案（「录音中…松开发送」等，由调用方传 l10n 文案）。
  final String hintText;

  @override
  State<RecordingOverlay> createState() => _RecordingOverlayState();
}

class _RecordingOverlayState extends State<RecordingOverlay> {
  // 波形采样窗口：新采样进队尾、队首挤出，形成自右向左的实时滚动效果
  static const int _maxSamples = 28;
  final List<double> _samples = List.filled(_maxSamples, 0.06);
  StreamSubscription<Amplitude>? _subscription;
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.amplitudeStream.listen((amplitude) {
      if (!mounted) return;
      // dBFS（约 -50 ~ 0）归一化到 0.06~1.0，并对上一采样做一阶平滑让波形更自然
      final raw = ((amplitude.current + 50) / 50).clamp(0.06, 1.0);
      setState(() {
        final last = _samples.isNotEmpty ? _samples.last : raw;
        _samples.add((last * 0.4 + raw * 0.6).clamp(0.06, 1.0));
        if (_samples.length > _maxSamples) _samples.removeAt(0);
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  String get _elapsedLabel =>
      '${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _elapsedLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (final sample in _samples)
                    Container(
                      width: 4,
                      height: 6 + sample * 34,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                widget.hintText,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
