import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 通用灰底按钮样式（老板 2026-10-18）：默认浅灰底 + 黑字，悬浮变深、
/// 按压再变深（5% → 10% → 14%，与「添加另一个秘境」Material+InkWell
/// 的分级一致）。半透明黑叠加出分级，按压高亮不会再把底色"吃掉"
/// （此前 FilledButton 直接换底色，按压时视觉上底色消失——已 revert 的教训）。
///
/// 「取消」（[CancelButton]）与通道码「重新生成」共用这一份，保证同类
/// 低强调按钮观感一致。
ButtonStyle grayButtonStyle() {
  return TextButton.styleFrom(
    backgroundColor: Colors.black.withValues(alpha: 0.05),
    foregroundColor: Colors.black,
    // 尺寸与字重同全局主题的 FilledButton（main.dart：96x50、17 号粗体）——
    // 提交/销毁/删除等主力按钮都是这个块头，取消按钮一样大，只靠颜色区分
    // （老板 2026-10-18，此前 64x40 仍明显偏小）
    padding: const EdgeInsets.symmetric(horizontal: 16),
    minimumSize: const Size(96, 50),
    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
  ).copyWith(
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  );
}

/// 按状态叠加的灰度（悬浮/按压变深）：叠在 [grayButtonStyle] 的 5% 底之上。
/// 悬浮 +5%（共 10%），按压 +9%（共 14%）。
WidgetStateProperty<Color?> _grayOverlay() {
  return WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.pressed)) {
      return Colors.black.withValues(alpha: 0.09);
    }
    if (states.contains(WidgetState.hovered)) {
      return Colors.black.withValues(alpha: 0.05);
    }
    return Colors.transparent;
  });
}

/// 通用淡灰底按钮（与 [CancelButton] 同一套样式，文案/动作自定）：
/// 用于弹窗里的**次要动作**——低强调，但有底色，一眼看出可点
/// （老板 2026-10-28：纯文字按钮太像说明文字）。
class GrayButton extends StatelessWidget {
  const GrayButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: grayButtonStyle().copyWith(overlayColor: _grayOverlay()),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 统一的「取消」按钮（老板 2026-10-18）：淡灰底色，取代此前各弹窗
/// 有的用边框（OutlinedButton）、有的纯文字无底色的不一致。
class CancelButton extends StatelessWidget {
  const CancelButton({super.key, this.onPressed, this.label});

  final VoidCallback? onPressed;

  /// 覆盖文案（缺省用通用 l10n「取消」）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextButton(
      style: grayButtonStyle().copyWith(overlayColor: _grayOverlay()),
      onPressed: onPressed,
      child: Text(label ?? l10n.cancel),
    );
  }
}
