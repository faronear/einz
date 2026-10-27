import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 「点按解锁编辑」的输入框基础组件（2026-10-20 抽公用）。
///
/// 「只读态 + 右侧编辑图标 → 点框内任意位置进编辑态」这套交互已在改名弹窗、
/// 锁屏码弹窗（新 PIN 框初始只读以示意"可略过"）两处出现，再内联必然漂移——
/// 抽成基础组件，小眼睛等特性由上层组合（见 PassphraseField）。
///
/// 两种状态：
/// - 只读态（[readOnly] 为 true 时初始）：透明底、右侧编辑图标；点框内任意
///   位置或图标 → 进编辑态；
/// - 编辑态：白底可输入，尾部换成 [editableSuffix]（如小眼睛；null = 无尾标）。
///
/// 语义用 **readOnly 而不是 enabled:false**：禁用框整个不吃点击，点框无法
/// 进入编辑态；readOnly 框仍派发 onTap，恰好承载"点任意处解锁"（与改名弹窗
/// 同手法——用 TextField 自带 onTap，不额外套 GestureDetector，避免与输入框
/// 内部手势抢 arena）。只读态点击不会自动取焦，进编辑态时对传入的
/// [focusNode] 显式 requestFocus（调用方要键盘即弹就传节点）。
class EditableField extends StatefulWidget {
  const EditableField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.keyboardType,
    this.inputFormatters,
    this.obscureText = false,
    this.maxLength,
    this.style,
    this.onChanged,
    this.editableSuffix,
    this.editIconTooltip,
    this.filled,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;
  final FocusNode? focusNode;
  final bool autofocus;

  /// true = 初始只读态（编辑图标尾标，点按解锁）；false = 一开始就可编辑。
  final bool readOnly;

  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool obscureText;
  final int? maxLength;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;

  /// 编辑态的尾部控件（小眼睛等）；null = 编辑态无尾标。只读态恒为编辑图标。
  final Widget? editableSuffix;

  /// 只读态编辑图标的 tooltip（如 l10n.chatPageEdit）。
  final String? editIconTooltip;

  /// 是否白底：null（默认）= 跟随编辑态（只读透明 / 编辑白，与改名弹窗一致）；
  /// false = 恒透明（保持普通输入框原观感，PassphraseField 组合时用）。
  final bool? filled;

  @override
  State<EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<EditableField> {
  late bool _editing = !widget.readOnly;

  void _enterEditing() {
    if (_editing) return;
    setState(() => _editing = true);
    // 只读态的点击不会自动取焦（readOnly 框不弹键盘），解锁后手动交焦
    widget.focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      readOnly: !_editing,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      obscureText: widget.obscureText,
      maxLength: widget.maxLength,
      style: widget.style,
      onChanged: widget.onChanged,
      onTap: _enterEditing, // 编辑态下是空操作（guard 挡住）
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
        // 三态底色（老板 2026-10-20：只读态不能与可编辑态同白，看不出"待激活"）：
        // - 调用方显式给 filled（false = 恒透明，PassphraseField 组合用）→ 照给；
        // - 否则编辑态白底、只读态淡灰——淡灰 = "这框还没激活/可略过"的视觉暗示
        filled: widget.filled ?? true,
        fillColor: _editing
            ? Colors.white
            // 用 onSurface 4% 而非固定灰值：深浅色主题下都与文字同源协调
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04),
        // 不显示 "n/32" 计数器（与改名弹窗同口径：上限只是防超长）
        counterText: '',
        suffixIcon: _editing
            ? widget.editableSuffix
            : IconButton(
                icon: const Icon(Icons.edit, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: _enterEditing,
              ),
      ),
    );
  }
}
