import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// 统一的「取消」按钮（老板 2026-10-18）：淡灰底色，取代此前各弹窗
/// 有的用边框（OutlinedButton）、有的纯文字无底色的不一致。
///
/// 淡灰 = surfaceContainerHighest（Material 3 中性容器色，深浅色模式自适应），
/// 前景色用 onSurfaceVariant，弱于主色/危险色——取消本就是低强调动作。
class CancelButton extends StatelessWidget {
  const CancelButton({super.key, this.onPressed, this.label});

  final VoidCallback? onPressed;

  /// 覆盖文案（缺省用通用 l10n「取消」）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: onPressed,
      child: Text(label ?? l10n.cancel),
    );
  }
}
