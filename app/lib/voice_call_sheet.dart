import 'dart:async';

import 'package:flutter/material.dart';

import 'data/voice_call_service.dart';
import 'l10n/app_localizations.dart';

/// 语音通话界面：振铃（来电/去电）与通话中的全屏层。
///
/// 用一个 Dialog 覆盖在当前页面之上（barrierDismissible: false——通话中不允许
/// 误触返回键把界面关掉，只能挂断）。状态全部来自 [VoiceCallService.state]，
/// 本文件只负责显示与转发按钮动作。
Future<void> showVoiceCallDialog(
  BuildContext context, {
  required VoiceCallService call,
  required String peerName,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (ctx) => _VoiceCallDialog(call: call, peerName: peerName),
  );
}

class _VoiceCallDialog extends StatefulWidget {
  const _VoiceCallDialog({required this.call, required this.peerName});

  final VoiceCallService call;
  final String peerName;

  @override
  State<_VoiceCallDialog> createState() => _VoiceCallDialogState();
}

class _VoiceCallDialogState extends State<_VoiceCallDialog> {
  Timer? _ticker;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // 通话计时：每 500ms 刷新一次（够用且省电——显示精度只到秒）
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    widget.call.state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.call.state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// 通话结束 → 自动关闭本层（结束原因由外层的提示条告诉用户）。
  void _onStateChanged() {
    if (widget.call.state.value.phase != VoiceCallPhase.ended) return;
    if (_closing) return;
    _closing = true;
    if (mounted) Navigator.of(context).pop();
  }

  String _statusText(AppLocalizations l10n) {
    final s = widget.call.state.value;
    switch (s.phase) {
      case VoiceCallPhase.ringing:
        return l10n.voiceCallIncoming;
      case VoiceCallPhase.calling:
        return l10n.voiceCallCalling;
      case VoiceCallPhase.connecting:
        return l10n.voiceCallConnecting;
      case VoiceCallPhase.active:
        return _formatDuration(s.startedAt);
      case VoiceCallPhase.idle:
      case VoiceCallPhase.ended:
        return '';
    }
  }

  String _formatDuration(DateTime? startedAt) {
    if (startedAt == null) return '00:00';
    final d = DateTime.now().difference(startedAt);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<VoiceCallState>(
      valueListenable: widget.call.state,
      builder: (context, s, _) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          child: SizedBox.expand(
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xF21B1B1F)),
              child: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    CircleAvatar(
                      radius: 44,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      child: const Icon(Icons.person, size: 44, color: Colors.white70),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      widget.peerName,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusText(l10n),
                      style: const TextStyle(fontSize: 15, color: Colors.white70),
                    ),
                    const Spacer(),
                    // 振铃阶段（含来电与去电）提示"必须双方都在前台"——不做后台呼入，
                    // 对方不在前台就是一直振铃到超时，得提前说清，别让人以为坏了
                    if (s.phase == VoiceCallPhase.ringing || s.phase == VoiceCallPhase.calling)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          l10n.voiceCallForegroundOnly,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ),
                    const SizedBox(height: 24),
                    _buildButtons(l10n, s),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildButtons(AppLocalizations l10n, VoiceCallState s) {
    switch (s.phase) {
      case VoiceCallPhase.ringing:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CallButton(
              icon: Icons.call_end,
              label: l10n.voiceCallDecline,
              color: const Color(0xFFE5484D),
              onTap: () => widget.call.reject(),
            ),
            _CallButton(
              icon: Icons.call,
              label: l10n.voiceCallAccept,
              color: const Color(0xFF30A46C),
              onTap: () => unawaited(widget.call.accept()),
            ),
          ],
        );
      case VoiceCallPhase.calling:
      case VoiceCallPhase.connecting:
        return _CallButton(
          icon: Icons.call_end,
          label: l10n.voiceCallCancel,
          color: const Color(0xFFE5484D),
          onTap: () => widget.call.hangUp(),
        );
      case VoiceCallPhase.active:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CallButton(
              icon: s.muted ? Icons.mic_off : Icons.mic,
              label: s.muted ? l10n.voiceCallUnmute : l10n.voiceCallMute,
              color: Colors.white12,
              onTap: () => widget.call.toggleMute(),
            ),
            _CallButton(
              icon: s.speaker ? Icons.volume_up : Icons.volume_off,
              label: s.speaker ? l10n.voiceCallSpeakerOff : l10n.voiceCallSpeaker,
              color: Colors.white12,
              onTap: () => unawaited(widget.call.toggleSpeaker()),
            ),
            _CallButton(
              icon: Icons.call_end,
              label: l10n.voiceCallHangUp,
              color: const Color(0xFFE5484D),
              onTap: () => widget.call.hangUp(),
            ),
          ],
        );
      case VoiceCallPhase.idle:
      case VoiceCallPhase.ended:
        return const SizedBox.shrink();
    }
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 88,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
      ],
    );
  }
}
