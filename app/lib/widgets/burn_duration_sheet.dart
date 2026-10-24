import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'labeled_checkbox.dart';

/// 阅后即焚时长的下限/上限（老板 2026-10-24：10 秒 ~ 50 天；此前为 1 分钟~
/// 60 天）。对数轴上最右的时长刻度要离「关闭」顶点足够远，拖/点稍偏不至于
/// 互相误触。
const int kBurnMinSeconds = 10; // 10 秒
const int kBurnMaxSeconds = 50 * 86400; // 50 天

/// 任意秒数 → 人类可读（天/时/分，零单位省略；不足 1 分钟才落到秒）。
/// 0/负数 → 「关闭（不再自动焚毁）」。
String formatBurnDuration(int seconds, AppLocalizations l10n) {
  if (seconds <= 0) return l10n.burnOptionOff;
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  final parts = <String>[
    if (days > 0) l10n.burnUnitDays(days),
    if (hours > 0) l10n.burnUnitHours(hours),
    if (minutes > 0) l10n.burnUnitMinutes(minutes),
    if (secs > 0) l10n.burnUnitSeconds(secs),
  ];
  return parts.join(' ');
}

/// 打开阅后即焚时长弹层（右上角菜单全局 / 长按菜单单条消息共用）。
/// 返回选中的秒数（0 = 关闭）与范围勾选态；取消/点外部/下滑返回 null。
///
/// [scopeAllLabel] 非空 = 在提交按钮上方渲染「应用于本机所有秘境」勾选框
/// （每次打开默认不勾选；调用方据此把设置写到所有空间）。逐条消息的燃焚
/// 没有"空间"维度，传 null 不渲染。
Future<({int seconds, bool scopeAll})?> showBurnDurationSheet({
  required BuildContext context,
  required int current,
  String? scopeAllLabel,
}) {
  return showModalBottomSheet<({int seconds, bool scopeAll})>(
    context: context,
    // 允许用满窗高（与其它选项弹层同口径，老板 2026-10-02）
    isScrollControlled: true,
    builder: (_) => BurnDurationSheet(current: current, scopeAllLabel: scopeAllLabel),
  );
}

/// 阅后即焚时长弹层（老板 2026-10-16）：从 6 个固定档位改为**任意时长**——
/// 一根对数刻度的滑动轴，1 分钟 ~ 60 天。两个关键设计：
///
/// 1. **粒度随时长升档**：1 小时内吸附到分钟、1 小时~1 天吸附到小时、1 天以上
///    只到天——拖出来永远是 "5 分钟 / 5 小时 / 3 天" 这样的干净值，不会出现
///    "5 小时 37 分"（老板 2026-10-16）。
/// 2. **右端是「关闭」特别顶点**：轴下方标注 1 分钟 / 1 小时 / 1 天 / 关闭四个
///    可点标注（点了立刻把轴跳到该点），最右端不标 60 天而是红色加粗的
///    「关闭」——拖到顶即关闭，往左拖恢复时长（双向可逆）。
///
/// 以「提交」落定：拖动途中不反复写盘/弹提示（与 OptionPickerSheet 的提交
/// 模式口径一致）。矮窗时主体内部滚动，标题/备注/提交固定。
///
/// [scopeAllLabel] 非空 = 提交按钮上方渲染「应用于本机所有秘境」勾选框
/// （复用 LabeledCheckbox，与设置弹层同款；每次打开默认不勾选）。
class BurnDurationSheet extends StatefulWidget {
  const BurnDurationSheet({super.key, required this.current, this.scopeAllLabel});

  /// 当前值（秒；0 = 关闭）。
  final int current;

  /// 「应用于本机所有秘境」勾选框的标签（null = 不渲染）。
  final String? scopeAllLabel;

  @override
  State<BurnDurationSheet> createState() => _BurnDurationSheetState();
}

class _BurnDurationSheetState extends State<BurnDurationSheet> {
  /// 滑动位置 t∈[0,1]（对数刻度；t=1 即最右端的「关闭」顶点）。
  late double _t;

  /// 「应用于本机所有秘境」勾选态（每次开弹窗默认不勾选）。
  bool _scopeAll = false;

  @override
  void initState() {
    super.initState();
    // 当前就是关闭 → 停在最右顶点；否则按当前值定位
    _t = widget.current <= 0 ? 1.0 : _tFromSeconds(widget.current);
  }

  /// 是否停在「关闭」顶点（唯一权威：轴到顶就是关，往左拖即恢复）。
  bool get _off => _t >= 1.0;

  int get _axisSeconds => _secondsFromT(_t);

  // ---- 轴刻度映射（**分段对数**：10 秒~1 分钟一段占前 1/4，1 分钟~50 天
  // 一段占后 3/4。单一对数轴上 10 秒~1 分钟只占整轴 ~8%，太挤；分段把这段
  // 拉长到 25%，同时保持段内对数刻度与档位吸附不变，老板 2026-10-24）----

  /// 分段点（秒）：短时长段与长时长段的分界，轴位置 [kBurnSplitT]。
  static const int _splitSeconds = 60;

  /// 分段点在轴上的位置（0~1）。
  static const double _splitT = 0.25;

  /// 轴位置 → 秒数：段内对数 + **粒度随时长升档**（见类文档）。
  static int _secondsFromT(double t) {
    final c = t.clamp(0.0, 1.0);
    final double raw;
    if (c <= _splitT) {
      // 短段：10 秒 → 1 分钟，段内线性映射到对数值
      final local = c / _splitT;
      raw = kBurnMinSeconds *
          math.pow(_splitSeconds / kBurnMinSeconds, local).toDouble();
    } else {
      // 长段：1 分钟 → 50 天
      final local = (c - _splitT) / (1 - _splitT);
      raw = _splitSeconds *
          math.pow(kBurnMaxSeconds / _splitSeconds, local).toDouble();
    }
    final int snapped;
    if (raw <= 3600) {
      // ≤1 小时：分钟吸附（10 秒~60 秒区段吸附到 10 秒，与锁屏轴同口径）
      snapped = raw <= 60 ? (raw / 10).round() * 10 : (raw / 60).round() * 60;
    } else if (raw <= 86400) {
      snapped = (raw / 3600).round() * 3600; // ≤1 天：小时
    } else {
      snapped = (raw / 86400).round() * 86400; // >1 天：天
    }
    return snapped.clamp(kBurnMinSeconds, kBurnMaxSeconds);
  }

  static double _tFromSeconds(int seconds) {
    final clamped = seconds.clamp(kBurnMinSeconds, kBurnMaxSeconds);
    if (clamped <= _splitSeconds) {
      // 短段：10 秒 → 1 分钟
      return _splitT *
          math.log(clamped / kBurnMinSeconds) /
          math.log(_splitSeconds / kBurnMinSeconds);
    }
    // 长段：1 分钟 → 50 天
    return _splitT +
        (1 - _splitT) *
            math.log(clamped / _splitSeconds) /
            math.log(kBurnMaxSeconds / _splitSeconds);
  }

  void _submit() => Navigator.of(context)
      .pop((seconds: _off ? 0 : _axisSeconds, scopeAll: _scopeAll));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题居中（与其它选项弹层口径一致）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 5),
            child: Center(
              child: Text(l10n.chatPageBurnHeading,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16)),
            ),
          ),
          // 备注：固定不滚、居中、归标题组（与 OptionPickerSheet 的 note 同款）
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: Center(
              child: Text(
                l10n.chatPageBurnNote,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, height: 1.4, color: scheme.outline),
              ),
            ),
          ),
          // 主体：矮窗时这一块内部滚动。整块套**白色分组卡片**（老板 2026-10-24，
          // 参照 PIN 弹窗的分组卡 surfaceContainerLowest + outlineVariant 细描边）
          // ——把"时间轴 + 当前值预览 + 轴下标注"圈成主要设置区，与弹层粉底分层。
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              child: Padding(
                // 12：与 OptionPickerSheet 的选项行/提交按钮同口径（老板 2026-10-24）
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest, // 白卡：与弹窗粉底分层
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.6)),
                  ),
                  child: _axisBody(l10n, scheme),
                ),
              ),
            ),
          ),
          // 「应用于本机所有秘境」勾选框（提交按钮上方：提交前统一确认
          // "选多久 + 作用域"，防呆——与 OptionPickerSheet 提交模式同位置；
          // 逐条消息燃焚传 null 不渲染）
          if (widget.scopeAllLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: LabeledCheckbox(
                value: _scopeAll,
                label: widget.scopeAllLabel!,
                onChanged: (v) => setState(() => _scopeAll = v),
              ),
            ),
          // 提交（满宽：表单主操作，与附件存储/墓碑的提交模式一致）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                child: Text(l10n.burnSubmit),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _axisBody(AppLocalizations l10n, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 实时预览：一句话说清后果（"延时 5 分钟 自动焚毁"）；停在「关闭」
        // 顶点时显示关闭文案
        Center(
          child: Text(
            _off
                ? l10n.burnOptionOff
                : l10n.burnPreviewDelay(formatBurnDuration(_axisSeconds, l10n)),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: _off ? scheme.outline : scheme.onSurface,
            ),
          ),
        ),
        Slider(
          value: _t,
          // 始终可拖：从最右的「关闭」顶点往左拖即恢复时长
          onChanged: (v) => setState(() => _t = v),
        ),
        _axisLabels(l10n, scheme),
      ],
    );
  }

  /// 轴下的方位标注：**1 分钟 / 1 小时 / 1 天**各标在其刻度位置上（1 小时与
  /// 1 天是长时长的两个心理锚点），最右端不标 60 天而是**「关闭」顶点**。
  /// 四个标注**都可点**（点了立刻把轴跳到该点），带悬浮/点击反馈（与选项行/
  /// 勾选框同款的 InkWell 淡色反馈）；「关闭」用红色加粗——停在这是"不再自动
  /// 焚毁"，值得醒目（老板 2026-10-16）。
  ///
  /// 标签 x 用与 Slider thumb 完全相同的几何（`trackLeft + t × trackWidth`，
  /// 见 SDK `BaseSliderTrackShape.getPreferredRect`），保证对准刻度。
  Widget _axisLabels(AppLocalizations l10n, ColorScheme scheme) {
    final theme = SliderTheme.of(context);
    final thumbWidth = theme.thumbShape?.getPreferredSize(true, false).width ?? 0;
    final overlayWidth = theme.overlayShape?.getPreferredSize(true, false).width ?? 0;
    final trackLeft = math.max(overlayWidth / 2, thumbWidth / 2);
    final trackInset = math.max(thumbWidth, overlayWidth);
    return LayoutBuilder(builder: (ctx, constraints) {
      final width = constraints.maxWidth;
      // 标注点（t 为轴位置；最后一个是右端顶点，右对齐避免伸出屏幕）。
      // 老板 2026-10-24：范围改 10 秒~50 天，左端标 10 秒，增加 1 分钟锚点。
      final marks = <({double t, String label, bool isOff, bool rightAligned})>[
        (t: 0, label: l10n.burnUnitSeconds(kBurnMinSeconds), isOff: false, rightAligned: false),
        (t: _tFromSeconds(60), label: l10n.burnUnitMinutes(1), isOff: false, rightAligned: false),
        (t: _tFromSeconds(3600), label: l10n.burnUnitHours(1), isOff: false, rightAligned: false),
        (t: _tFromSeconds(86400), label: l10n.burnUnitDays(1), isOff: false, rightAligned: false),
        (t: 1, label: l10n.burnAxisOffLabel, isOff: true, rightAligned: true),
      ];
      return SizedBox(
        height: 30,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final mark in marks)
              Align(
                alignment: Alignment(
                    mark.rightAligned
                        ? 1
                        : 2 * (trackLeft + mark.t * (width - trackInset)) / width - 1,
                    -1),
                child: _axisLabelChip(
                  label: mark.label,
                  isOff: mark.isOff,
                  scheme: scheme,
                  onTap: () => setState(() => _t = mark.t), // 点标注 → 轴跳到该点
                ),
              ),
          ],
        ),
      );
    });
  }

  /// 轴下的单个可点标注：默认就有一层淡背景色（提示可点——老板 2026-10-16：
  /// 不等悬浮才知道能点），加 InkWell 悬浮/点击反馈；「关闭」红色加粗更醒目。
  Widget _axisLabelChip({
    required String label,
    required bool isOff,
    required ColorScheme scheme,
    required VoidCallback onTap,
  }) {
    return Material(
      // 默认淡背景：非关闭标主色极淡，关闭标错误色极淡（呼应文字颜色）
      color: isOff
          ? scheme.error.withValues(alpha: 0.08)
          : scheme.primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.black.withValues(alpha: 0.05),
        highlightColor: Colors.black.withValues(alpha: 0.08),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isOff ? 12 : 11,
              height: 1.2,
              fontWeight: isOff ? FontWeight.w600 : FontWeight.w400,
              // 「关闭」顶点：红色加粗提醒（其余标注用淡灰）
              color: isOff ? scheme.error : scheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}
