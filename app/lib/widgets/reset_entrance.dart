import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../widgets/top_notice.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';

/// 破坏性操作的确认弹窗文案（当前只有空间级「销毁本秘境通道」用，结构留给将来的破坏性操作）。
class ConfirmDialogCopy {
  const ConfirmDialogCopy({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;
}

/// 弹出闸门（通道名 + 已设时的锁屏码），两道都对返回 true。
///
/// **闸门故意只用本机独占的因子**（老板 2026-09-22 定稿）：通道名确认清的是这条，
/// 锁屏码是本地秘密。刻意**不校验空间口令**——那是**共享**给伴侣的加入凭证，不该获得
/// 销毁我这条通道的权力；而且校验它必须联网，会让"这条通道连的服务器已经连不上"
/// 这个最常见的重置场景直接自锁（详情见 `server/src/entrances.ts` 的 retireEntrance）。
///
/// 本机级的「清除本设备全部数据」已删除（2026-09-22）→ 当前只有空间级「销毁本秘境通道」用它。
Future<bool> _confirmDestructive(
  BuildContext context, {
  required LocalDatabase db,
  required String entranceName,
  required bool hasPin,
  required ConfirmDialogCopy copy,
}) async {
  if (!context.mounted) return false;
  // 通道名取不到（本地快照与服务端都问不出来）时退一步：改让用户打一个固定确认词。
  // 不可用性优先——本地快照缺 entranceName 的旧装机不该因此永远清不掉。
  final l10n = AppLocalizations.of(context)!;
  final expected =
      entranceName.trim().isEmpty ? l10n.resetEntranceConfirmWord : entranceName.trim();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConfirmDestructiveDialog(
      db: db,
      entranceName: expected,
      hasPin: hasPin,
      copy: copy,
    ),
  );
  return ok ?? false;
}

/// 尽力而为地让服务端退役**一个空间**的那条虚拟通道（只影响这一个空间的那一行）。
///
/// 失败不阻塞本地移除（本地移除才是用户要的结果），但**要把失败如实告诉用户**：
/// 退役没成功 = 对方通道列表里这条通道仍是 active 的幽灵。返回是否成功，由调用方提示。
Future<bool> retireSpaceQuietly(String token, {ApiClient? api}) async {
  if (token.isEmpty) return false;
  try {
    await (api ?? ApiClient(effectiveServer)).retireEntrance(token);
    return true;
  } catch (_) {
    // 离线 / 已被对方撤销 / 老服务端
    return false;
  }
}

/// 「销毁本秘境通道」——**空间级**破坏性操作（聊天页菜单 → 高级）。
///
/// 语义（老板 2026-09-22 定）：站在某个空间里点破坏性入口，用户心里想的就是"结束这个
/// 空间"，不该顺手抹掉本机上的其他空间。所以这里只做：
/// ① 服务端退役**这个空间**那一行（best-effort，失败照清）；② 本地 removeSpace(spaceId)。
/// 整台设备的清理由空间列表页的「清除本设备全部数据」负责。
///
/// 返回 true 表示已完成（调用方负责导航）。
Future<bool> confirmLeaveSpace(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
  required String spaceId,
  required String token,
  required String entranceName,
  bool hasPin = false,
}) async {
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  final ok = await _confirmDestructive(
    context,
    db: database,
    entranceName: entranceName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.leaveSpaceTitle,
      message: l10n.leaveSpaceMessage,
      confirmLabel: l10n.leaveSpaceConfirm,
    ),
  );
  if (!ok || !context.mounted) return false;

  // 服务端退役：尽力而为（顺序不能反——token 在本地，清完就再也调不动它了）。
  // 只影响这一个空间那一行，其他空间的通道行不动。失败如实提示（顶部通知挂在根
  // Overlay 上，本页随后 pop 也不影响它显示）。
  final retired = await retireSpaceQuietly(token, api: api);
  // PIN 模式下这里没有 pin（聊天页不持有）→ removeSpace 走"挂 pending + 立即清数据"，
  // 凭证条目等下次解锁再摘（见 AppLockService.removeSpace 文档）。
  await AppLockService(database).removeSpace(spaceId);
  if (!retired && context.mounted) {
    showTopNotice(context, l10n.resetEntranceServerResidualHint);
  }
  return true;
}

// 「清除本设备全部数据」（本机级）**已删除**（老板 2026-09-22：太危险，不呈现给用户）。
// 用户的等价路径：逐个空间「销毁本秘境通道」，或直接卸载重装（ensureFreshInstall
// 会清掉残留密钥）。`data/local_reset.dart` 的 resetLocalData() 作为"整机清空"原语保留。

/// 破坏性操作共用的确认弹窗：说明小字 + 输入通道名（+已设时的锁屏码）。
///
/// 文案由 [copy] 注入（空间级 / 本机级各一套）。
class _ConfirmDestructiveDialog extends StatefulWidget {
  const _ConfirmDestructiveDialog({
    required this.db,
    required this.entranceName,
    required this.hasPin,
    required this.copy,
  });

  final LocalDatabase db;
  final String entranceName;
  final bool hasPin;
  final ConfirmDialogCopy copy;

  @override
  State<_ConfirmDestructiveDialog> createState() => _ConfirmDestructiveDialogState();
}

class _ConfirmDestructiveDialogState extends State<_ConfirmDestructiveDialog> {
  final _nameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _busy = false; // 锁屏码校验中（Argon2id 解包）：防连点重复提交

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    final name = _nameCtrl.text.trim();
    final pin = _pinCtrl.text;

    // ① 通道名：精确比对（trim 后大小写敏感——通道名是用户自己起的，不像邮箱该宽容）
    if (name != widget.entranceName) {
      setState(() => _error = l10n.resetEntranceNameMismatch);
      return;
    }
    // ② 锁屏码（已设才验）：走 AppLockService.unlock —— 与锁屏同一套防爆破
    // （连错 5 次锁 30 秒）；这里只是借用它的校验结果，成功即放行。
    if (widget.hasPin) {
      if (pin.isEmpty) {
        setState(() => _error = l10n.verifyPinRequired);
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await AppLockService(widget.db).unlock(pin);
      } on AppLockLockedException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.lockPageTooManyAttempts(e.remainingSeconds);
        });
        return;
      } on AppLockException {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.verifyPinWrong;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.setPinDialogSetupFailed('$e');
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.copy.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.copy.message,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.resetEntranceNameHint(widget.entranceName),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _nameCtrl,
            autofocus: true, // 闸门第一个框：打开弹窗即待输入
            decoration: InputDecoration(
              hintText: l10n.resetEntranceNameLabel(widget.entranceName),
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.hasPin) ...[
            const SizedBox(height: 8),
            Text(
              l10n.resetEntrancePinHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: l10n.resetEntrancePinLabel,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _busy ? null : _submit,
          child: Text(widget.copy.confirmLabel),
        ),
      ],
    );
  }
}
