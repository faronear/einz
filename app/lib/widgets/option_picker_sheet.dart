import 'package:flutter/material.dart';

/// 统一的选项弹层（界面语言 / 阅后即焚 / 附件存储共用，老板要求 2026-09-15）。
///
/// 约定（与界面主题弹层一致）：
/// - **无右上角关闭按钮**：下滑 / 点外部 / 返回键即关闭（底部弹层自带这些手势），
///   省一个按钮、也让几个弹层的观感统一；
/// - **当前选中项必须有背景高亮**（浅色 tint + 对勾），给用户明确的"现在是这个"；
/// - 点选即生效（[submitLabel] 为空）；给 [submitLabel] 时改为"单选 + 提交"
///   （用于**有副作用**的开关，如附件存储切回「远程托管」会删掉已存明文）。
class OptionPickerSheet extends StatefulWidget {
  const OptionPickerSheet({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onApply,
    this.submitLabel,
    this.warningFor,
    this.note,
  });

  /// 标题（弹层顶部居中/左对齐的一行）。
  final String title;

  /// 标题下方那行**居中的小字备注**（null = 不显示）。
  ///
  /// 用来把这层是干什么的一句话说清楚（阅后即焚："倒计时删除已阅读的新消息"）。
  /// 与标题**同居中**、字号更小更淡，靠"贴近标题、离选项更远"的间距表明它属于
  /// 标题那一组，而不是内容主体。
  final String? note;

  /// 可选项（按给定顺序展示）。
  final List<OptionPickerItem> options;

  /// 当前生效的值（高亮它）。
  final String selected;

  /// 生效回调：点选（或提交）后调用，执行完弹层自动关闭。
  final Future<void> Function(String value) onApply;

  /// 非空 = 需要底部「提交」按钮（不点选即生效）；为空 = 点选即生效。
  final String? submitLabel;

  /// 选中某值时显示的红字警示（会删除数据等副作用时用），返回 null 表示不显示。
  final String? Function(String value)? warningFor;

  @override
  State<OptionPickerSheet> createState() => _OptionPickerSheetState();
}

/// 一个选项：[value] 为存库值，[label] 主文案，[description] 可选副标题。
class OptionPickerItem {
  const OptionPickerItem({
    required this.value,
    required this.label,
    this.description,
  });

  final String value;
  final String label;
  final String? description;
}

class _OptionPickerSheetState extends State<OptionPickerSheet> {
  late String _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.selected;
  }

  bool get _needsSubmit => widget.submitLabel != null;

  Future<void> _apply(String value) async {
    await widget.onApply(value);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warning = widget.warningFor?.call(_picked);
    return SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题**居中**（老板 2026-09-15）：靠左会与下面的选项行分不清层次
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Center(
                child: Text(widget.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16)),
              ),
            ),
            // 标题下的小备注（老板 2026-09-25）。三级区分全靠字号/字重/颜色：
            // 标题 16/w600/主色 · 备注 12/常规/**outline**（比选项说明更淡一档，
            // 老板 2026-09-25：onSurfaceVariant 和选项的 12px 说明同色，看着糊）·
            // 选项 15/w600 + 12 说明。
            // 间距上贴着标题（上 0）、离选项远一点（下 14），表明它归标题那一组。
            if (widget.note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                child: Center(
                  child: Text(
                    widget.note!,
                    // 换行后的每一行都要居中（Center 只管整块，不管行内对齐）
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        // outline 比 onSurfaceVariant 更淡：不用和选项的 12px 说明
                        // 撞成同一档灰；弹窗内"大标题下的小字说明"本就用这一档
                        color: scheme.outline),
                  ),
                ),
              ),
            // 选项区可滚动：档位多（阅后即焚 6 档）+ 窗口不高时，原先是死 Column →
            // 底部内容被裁掉并报 RenderFlex overflow（老板 2026-09-24 要求改可滚动）。
            // 标题与底部「提交」按钮固定，只有中间这几行滚。
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in widget.options)
                      _OptionRow(
                        option: option,
                        // 提交模式高亮"待提交的选择"；点选即生效模式高亮当前生效值
                        active: option.value == _picked,
                        onTap: _needsSubmit
                            ? () => setSheetState(() => _picked = option.value)
                            : () => _apply(option.value),
                      ),
                    if (warning != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(warning,
                              style: TextStyle(fontSize: 12, color: scheme.error)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_needsSubmit)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    // 没改动：不必提交
                    onPressed:
                        _picked == widget.selected ? null : () => _apply(_picked),
                    child: Text(widget.submitLabel!),
                  ),
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 单选项行：**选中项有背景高亮**（浅 tint 圆角 + 对勾）——几个设置弹层统一。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.active,
    required this.onTap,
  });

  final OptionPickerItem option;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: active
            ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(option.label,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      if (option.description != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          option.description!,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (active)
                  Icon(Icons.check, size: 20, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
