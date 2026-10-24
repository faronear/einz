import 'package:flutter/material.dart';

import 'labeled_checkbox.dart';

/// 打开选项弹层（界面语言 / 阅后即焚 / 附件存储共用的入口）。
///
/// `isScrollControlled`：解除默认 9/16 屏高上限，允许弹层用到满窗高——桌面窗口
/// 缩小时弹层高度保持到窗口压到其上边沿才一起往下压（与「我的通道」等弹层同
/// 口径，老板 2026-10-02）；内容矮时仍贴合内容，手机上看不出差别。选项区本身
/// 可滚（见 [_OptionPickerSheetState.build]），矮窗由滚动吸收。
Future<T?> showOptionPickerSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: builder,
  );
}

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
    this.scopeAllLabel,
    this.initialScopeAll = false,
  });

  /// 标题（弹层顶部居中/左对齐的一行）。
  final String title;

  /// 标题下方那行**居中的小字备注**（null = 不显示）。
  ///
  /// 用来把这层是干什么的一句话说清楚（阅后即焚："倒计时删除已阅读的新消息"）。
  /// 与标题**同居中**、字号更小更淡，靠"贴近标题、离选项更远"的间距表明它属于
  /// 标题那一组，而不是内容主体。
  final String? note;

  /// 「作用于本机所有空间」勾选框的标签（null = 不显示勾选框；老板 2026-10-15）。
  ///
  /// 勾选态由本弹层持有（[_OptionPickerSheetState._scopeAll]），点选选项时随
  /// [onApply] 的 `scopeAll` 一并交出——调用方据此决定写 per-space 键还是全局键。
  final String? scopeAllLabel;

  /// 勾选框的初始态（每次开弹层都是 false：默认只作用于当前空间）。
  final bool initialScopeAll;

  /// 可选项（按给定顺序展示）。
  final List<OptionPickerItem> options;

  /// 当前生效的值（高亮它）。
  final String selected;

  /// 生效回调：点选（或提交）后调用，执行完弹层自动关闭。
  /// [scopeAll] = 「作用于本机所有空间」勾选框的当前态（未显示勾选框时恒 false）。
  final Future<void> Function(String value, {bool scopeAll}) onApply;

  /// 非空 = 需要底部「提交」按钮（不点选即生效）；为空 = 点选即生效。
  final String? submitLabel;

  /// 选中某值时显示的红字警示（会删除数据等副作用时用），返回 null 表示不显示。
  final String? Function(String value)? warningFor;

  @override
  State<OptionPickerSheet> createState() => _OptionPickerSheetState();
}

/// 一个选项：[value] 为存库值，[label] 主文案，[description] 可选副标题，
/// [preview] 可选**前置预览图**（Theme 弹层的渐变/纯色缩略卡；非空时该行改为
/// 「预览图 + 文字」横向布局，与 ui_style_picker 原卡片同款）。
class OptionPickerItem {
  const OptionPickerItem({
    required this.value,
    required this.label,
    this.description,
    this.preview,
  });

  final String value;
  final String label;
  final String? description;

  /// 可选预览 widget（如 Theme 选项的配色缩略卡）。非空 = 行布局带前置预览。
  final Widget? preview;
}

class _OptionPickerSheetState extends State<OptionPickerSheet> {
  late String _picked;
  late bool _scopeAll;

  @override
  void initState() {
    super.initState();
    _picked = widget.selected;
    _scopeAll = widget.initialScopeAll;
  }

  bool get _needsSubmit => widget.submitLabel != null;

  Future<void> _apply(String value) async {
    await widget.onApply(value, scopeAll: _scopeAll);
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
            // 标题**居中**（老板 2026-09-15）：靠左会与下面的选项行分不清层次。
            // 下边距 5（老板 2026-10-02：原标题-备注 10 太开，减半增加整体感；
            // 有 note 的弹层由此获得紧凑的标题组）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 5),
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
            // 「作用于本机所有空间」勾选框（老板 2026-10-15）。位置按弹层模式分化：
            // - **点选即生效**（无提交按钮）：放选项区**上方**（标题+备注下）——
            //   选项即"提交"，放下方用户先点到选项、sheet 随即关闭，没机会改范围；
            // - **单选+提交**：放**提交按钮上方**（选项区下方）——提交前统一确认
            //   "选什么 + 作用域"，防呆（老板 2026-10-15 体验后拍板）。
            // 两种情况下都固定不随选项滚动；不传 scopeAllLabel 的弹层整个不渲染。
            if (widget.scopeAllLabel != null && !_needsSubmit)
              _scopeAllCheckbox(),
            // 选项区可滚动：档位多（阅后即焚 6 档）+ 窗口不高时，原先是死 Column →
            // 底部内容被裁掉并报 RenderFlex overflow（老板 2026-09-24 要求改可滚动）。
            // 标题/勾选框与底部「提交」按钮固定，只有中间这几行滚。
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
            // 单选+提交模式下，勾选框放**提交按钮上方**（选项区下方）
            if (widget.scopeAllLabel != null && _needsSubmit)
              _scopeAllCheckbox(),
            if (_needsSubmit)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    // 选项与作用域都没动：不必提交。**勾选态也算改动**——只勾
                    // "所有秘境"不改选项同样是有效操作（把当前模式推广到所有
                    // 空间），必须能提交（老板 2026-10-15）。
                    onPressed: (_picked == widget.selected &&
                            _scopeAll == widget.initialScopeAll)
                        ? null
                        : () => _apply(_picked),
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

  /// 「作用于本机所有空间」勾选框行（两个位置共用：选项区上方 / 提交按钮上方）。
  Widget _scopeAllCheckbox() => Padding(
        // 底部 4：与下方内容（选项行 / 提交按钮）之间留出分组感
        padding: const EdgeInsets.only(bottom: 4),
        child: LabeledCheckbox(
          label: widget.scopeAllLabel!,
          value: _scopeAll,
          onChanged: (v) => setState(() => _scopeAll = v),
        ),
      );
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
        // 未选中项的**默认灰**与「我的秘境」弹层「添加秘境」按钮统一为 5% 黑
        // （老板 2026-10-24：三态口径——默认 5% → 悬浮 10% → 点击 14%）。
        // 选中项**深粉**（老板 2026-10-24：原 secondaryContainer 55% 淡粉与 5%
        // 灰对比不足；改品牌粉 25% 实底，与 Theme 弹层选中态同款）。
        color: active
            ? const Color(0xFFD6529C).withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(12),
          hoverColor: Colors.black.withValues(alpha: 0.10),
          highlightColor: Colors.black.withValues(alpha: 0.14),
          onTap: onTap,
          child: Padding(
            // 带 preview 的行（Theme 迁移）体量更大：垂直内边距从 10 加到 12，
            // 预览图 64 高不至于贴边（与原 ui_style_picker 卡片体量一致）。
            padding: option.preview != null
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 12)
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // 前置预览图（Theme 弹层的渐变/纯色缩略卡；有 preview 的选项行
                // 垂直内边距加大一圈，与原 ui_style_picker 卡片体量一致）。
                if (option.preview != null) ...[
                  option.preview!,
                  const SizedBox(width: 12),
                ],
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
