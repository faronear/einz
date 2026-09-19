import 'package:flutter/material.dart';

import '../data/local_database.dart';
import '../data/local_reset.dart';
import '../l10n/app_localizations.dart';
import '../setup_page.dart';

/// 「重置设备」：清空本设备数据并回到新设备入网起点。
///
/// 入口：对话页菜单 → 高级（底部弹层）→ 重置设备，见 `chat_page._showAdvancedSheet`。
/// 之所以收进二级，是因为它极少用、且不可逆——常规用户不该在菜单里直接撞见破坏性操作。
///
/// 两组场景：
/// - 开发：用 `--server` 连开发服务器测完，本机身份属于那台服务器，连回生产既用不了
///   也没有别的入口能卸掉（手机端尤其没有——以前只有桌面端 `--reset` 能救）；
/// - 用户：分手后要重置本设备、重新开始。
///
/// **语义边界**：这里只清**本设备**。秘境本身仍保留在服务器上、对方的设备不受影响，
/// 要重新进入需要对方发新的邀请（服务端"解散秘境"是另一件事，尚未实现）。
Future<void> confirmResetDevice(BuildContext context, {LocalDatabase? db}) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.resetDeviceTitle),
          content: Text(l10n.resetDeviceMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.resetDeviceConfirm),
            ),
          ],
        ),
      ) ??
      false;
  if (!ok) return;
  await resetLocalData(db ?? LocalDatabase.shared);
  if (!context.mounted) return;
  // 清到根再进向导：中途的锁屏页/聊天页都不能留在栈上（它们的密钥已失效）
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const SetupPage()),
    (route) => false,
  );
}
