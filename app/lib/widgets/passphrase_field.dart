import 'dart:async';

import 'package:flutter/material.dart';

/// 口令输入框：默认暗码，右侧眼睛点一下看明文、**3 秒后自动回到暗码**。
///
/// 为什么抽成共用组件（2026-09-15）：ChatPage 的"改口令"弹窗与 SetupPage 的
/// "设置/验证共享口令"步骤都要这个行为——两份实现必然漂移（此前只有弹窗有眼睛，
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
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;

  /// 是否进入时自动聚焦（向导步骤首框用，让键盘直接弹起待输入）。
  final bool autofocus;

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

  /// 眼睛的焦点节点：`skipTraversal` → 桌面版按 TAB 时**跳过**这个小眼睛，
  /// 焦点从本输入框直接去下一个输入框（老板 2026-09-22）。
  ///
  /// 为什么是"跳过"而不是"把眼睛挪到最后一个输入框"（上一版做法，已撤回）：
  /// 眼睛留在需要它的输入框上才有用（输错了想看一眼），挪走等于为了绕开 TAB
  /// 而牺牲功能。skipTraversal 两全——鼠标点、键盘可达性都照旧，只是不挡路。
  /// 全 App 只有这里做"小眼睛看明文"，改一处即可覆盖创建向导与修改口令弹窗。
  late final FocusNode _revealFocusNode =
      FocusNode(skipTraversal: true, debugLabel: 'passphrase-reveal');

  @override
  void dispose() {
    _timer?.cancel();
    _revealFocusNode.dispose();
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
      autofocus: widget.autofocus,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
        suffixIcon: widget.showReveal
            ? IconButton(
                focusNode: _revealFocusNode, // TAB 跳过（见字段注释）
                icon: Icon(_revealed ? Icons.visibility : Icons.visibility_off),
                tooltip: widget.revealTip,
                onPressed: _toggle,
              )
            : null,
      ),
    );
  }
}
