import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editable_field.dart';

/// 口令输入框：默认暗码，右侧眼睛点一下看明文、**3 秒后自动回到暗码**。
///
/// 为什么抽成共用组件（2026-09-15）：ChatPage 的"改口令"弹窗与 SetupPage 的
/// "设置/验证共享口令"步骤都要这个行为——两份实现必然漂移（此前只有弹窗有眼睛，
/// 向导里没有）。眼睛的显隐规则由调用方决定（`showReveal`）：
/// **确认输入框不给眼睛**——确认框的用途是复核，给"看一眼"反而容易顺手点开。
///
/// 2026-10-20 重构：框体（边框/label/焦点/键盘等）下沉到基础组件
/// [EditableField]（「点按解锁编辑」状态机也在那里），本组件只保留**小眼睛**
/// 这一个特性——眼睛作为 `editableSuffix` 注入，两特性不再互相纠缠。
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
    this.focusNode,
    this.keyboardType,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;

  /// 是否进入时自动聚焦（向导步骤首框用，让键盘直接弹起待输入）。
  final bool autofocus;

  /// 外部焦点节点：向导切步骤后由页面显式 requestFocus（见 SetupPage 的同名说明）。
  final FocusNode? focusNode;

  /// 眼睛的 tooltip 文案（`showReveal: false` 时可省）。
  final String? revealTip;

  /// 是否给"查看明文"的眼睛（默认给；确认框传 false）。
  final bool showReveal;

  final TextStyle? style;
  final ValueChanged<String>? onChanged;

  /// 键盘类型与输入过滤（锁屏码等纯数字场景用；老板 2026-10-19：锁屏码
  /// 输入框统一复用本组件的小眼睛行为）。
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

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
    return EditableField(
      controller: widget.controller,
      labelText: widget.labelText,
      hintText: widget.hintText,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      obscureText: !_revealed, // 恒暗码框架；明文态由眼睛的 _revealed 接管
      style: widget.style,
      onChanged: widget.onChanged,
      // 白底观感与旧版保持一致（旧 PassphraseField 是普通 TextField，无
      // "编辑态白底"切换）；只读/编辑状态机按需由上层另用 EditableField。
      filled: false,
      // 眼睛在**编辑与暗码两个维度都成立**：EditableField 的 suffix 随编辑态
      // 恒展示（本组件不开只读态，所以等于常驻）；明/暗由 _revealed 决定。
      editableSuffix: widget.showReveal
          ? IconButton(
              focusNode: _revealFocusNode, // TAB 跳过（见字段注释）
              icon: Icon(_revealed ? Icons.visibility : Icons.visibility_off),
              tooltip: widget.revealTip,
              onPressed: _toggle,
            )
          : null,
    );
  }
}
