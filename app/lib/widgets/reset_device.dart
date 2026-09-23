import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../widgets/top_notice.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';

/// 破坏性操作的确认弹窗文案（空间级 / 设备级共用同一套结构，只换字）。
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

/// 弹出闸门（本机设备名 + 已设时的锁屏码），两道都对返回 true。
///
/// **闸门故意只用本机独占的因子**（老板 2026-09-22 定稿）：设备名确认清的是这台，
/// 锁屏码是本地秘密。刻意**不校验空间口令**——那是**共享**给伴侣的加入凭证，不该获得
/// 销毁我这台设备的权力；而且校验它必须联网，会让"本机身份属于一台已经连不上的服务器"
/// 这个最常见的重置场景直接自锁（详情见 `server/src/devices.ts` 的 retireDevice）。
///
/// 两个场景共用它：空间级「销毁本秘境通道」与设备级「清除本设备全部数据」。
Future<bool> _confirmDestructive(
  BuildContext context, {
  required LocalDatabase db,
  required String deviceName,
  required bool hasPin,
  required ConfirmDialogCopy copy,
}) async {
  if (!context.mounted) return false;
  // 设备名取不到（本地快照与服务端都问不出来）时退一步：改让用户打一个固定确认词。
  // 不可用性优先——本地快照缺 deviceName 的旧装机不该因此永远清不掉。
  final l10n = AppLocalizations.of(context)!;
  final expected =
      deviceName.trim().isEmpty ? l10n.resetDeviceConfirmWord : deviceName.trim();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConfirmDestructiveDialog(
      db: db,
      deviceName: expected,
      hasPin: hasPin,
      copy: copy,
    ),
  );
  return ok ?? false;
}

/// 尽力而为地让服务端退役**一个空间**的那台虚拟设备（只影响这一个空间的那一行）。
///
/// 失败不阻塞本地移除（本地移除才是用户要的结果），但**要把失败如实告诉用户**：
/// 退役没成功 = 对方设备列表里这台设备仍是 active 的幽灵。返回是否成功，由调用方提示。
Future<bool> retireSpaceQuietly(String token, {ApiClient? api}) async {
  if (token.isEmpty) return false;
  try {
    await (api ?? ApiClient(effectiveServer)).retireDevice(token);
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
  required String deviceName,
  bool hasPin = false,
}) async {
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  final ok = await _confirmDestructive(
    context,
    db: database,
    deviceName: deviceName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.leaveSpaceTitle,
      message: l10n.leaveSpaceMessage,
      confirmLabel: l10n.spaceListDeleteConfirm,
    ),
  );
  if (!ok || !context.mounted) return false;

  // 服务端退役：尽力而为（顺序不能反——token 在本地，清完就再也调不动它了）。
  // 只影响这一个空间那一行，其他空间的设备行不动。失败如实提示（顶部通知挂在根
  // Overlay 上，本页随后 pop 也不影响它显示）。
  final retired = await retireSpaceQuietly(token, api: api);
  // PIN 模式下这里没有 pin（聊天页不持有）→ removeSpace 走"挂 pending + 立即清数据"，
  // 凭证条目等下次解锁再摘（见 AppLockService.removeSpace 文档）。
  await AppLockService(database).removeSpace(spaceId);
  if (!retired && context.mounted) {
    showTopNotice(context, l10n.resetDeviceServerResidualHint);
  }
  return true;
}

// 「清除本设备全部数据」（设备级）**已删除**（老板 2026-09-22：太危险，不呈现给用户）。
// 用户的等价路径：逐个空间「销毁本秘境通道」，或直接卸载重装（ensureFreshInstall
// 会清掉残留密钥）。`data/local_reset.dart` 的 resetLocalData() 作为"整机清空"原语保留。

/// 破坏性操作共用的确认弹窗：说明小字 + 输入本机设备名（+已设时的锁屏码）。
///
/// 文案由 [copy] 注入（空间级 / 设备级各一套）。
class _ConfirmDestructiveDialog extends StatefulWidget {
  const _ConfirmDestructiveDialog({
    required this.db,
    required this.deviceName,
    required this.hasPin,
    required this.copy,
  });

  final LocalDatabase db;
  final String deviceName;
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

    // ① 设备名：精确比对（trim 后大小写敏感——设备名是用户自己起的，不像邮箱该宽容）
    if (name != widget.deviceName) {
      setState(() => _error = l10n.resetDeviceNameMismatch);
      return;
    }
    // ② 锁屏码（已设才验）：走 AppLockService.unlock —— 与锁屏同一套防爆破
    // （连错 5 次锁 30 秒）；这里只是借用它的校验结果，成功即放行。
    if (widget.hasPin) {
      if (pin.isEmpty) {
        setState(() => _error = l10n.chatPageSetLockOldRequired);
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
          _error = l10n.setPinDialogOldWrong;
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
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: l10n.resetDeviceNameLabel(widget.deviceName),
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.hasPin) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.resetDevicePinLabel,
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
