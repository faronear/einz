import 'dart:async';

import 'package:flutter/material.dart';

/// 口令输入框：默认暗码，右侧眼睛点一下看明文、**3 秒后自动回到暗码**。
///
/// 为什么抽成共用组件（2026-09-15）：ChatPage 的"改口令"弹窗与 SetupPage 的
/// "设置/验证密保口令"步骤都要这个行为——两份实现必然漂移（此前只有弹窗有眼睛，
/// 向导里没有）。眼睛的显隐规则由调用方决定（`showReveal`）：
/// **确认输入框不给眼睛**——确认框的用途是复核，给"看一眼"反而容易顺手点开。
class PassphraseField extends StatefulWidget {
  const PassphraseField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.revealTip,
    this.showReveal = true,
    this.style,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;

  /// 眼睛的 tooltip 文案（`showReveal: false` 时可省）。
  final String? revealTip;

  /// 是否给"查看明文"的眼睛（默认给；确认框传 false）。
  final bool showReveal;

  final TextStyle? style;
  final ValueChanged<String>? onChanged;

  @override
  State<PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<PassphraseField> {
  bool _revealed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() => _revealed = !_revealed);
    _timer?.cancel();
    if (_revealed) {
      // 明文只停留 3 秒：防止"点开忘关"把口令晾在屏幕上
      _timer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _revealed = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      style: widget.style,
      obscureText: !_revealed,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
        suffixIcon: widget.showReveal
            ? IconButton(
                icon: Icon(_revealed ? Icons.visibility : Icons.visibility_off),
                tooltip: widget.revealTip,
                onPressed: _toggle,
              )
            : null,
      ),
    );
  }
}
