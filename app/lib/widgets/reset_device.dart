import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../data/local_reset.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';
import '../setup_page.dart';
import '../widgets/top_notice.dart';

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
/// 两个场景共用它：空间级「退出并清除这个空间」与设备级「清除本设备全部数据」。
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
/// 失败静默：离线、已被对方撤销、老服务端——都不该阻止本地移除（本地移除才是用户
/// 要的结果）。服务端是否会残留这台设备，由调用方的确认文案事先说明。
Future<void> retireSpaceQuietly(String token, {ApiClient? api}) async {
  if (token.isEmpty) return;
  try {
    await (api ?? ApiClient(effectiveServer)).retireDevice(token);
  } catch (_) {
    // 忽略
  }
}

/// 「退出并清除这个空间」——**空间级**破坏性操作（聊天页菜单 → 高级）。
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
  // 只影响这一个空间那一行，其他空间的设备行不动。
  await retireSpaceQuietly(token, api: api);
  // PIN 模式下这里没有 pin（聊天页不持有）→ removeSpace 走"挂 pending + 立即清数据"，
  // 凭证条目等下次解锁再摘（见 AppLockService.removeSpace 文档）。
  await AppLockService(database).removeSpace(spaceId);
  return true;
}

/// 「清除本设备全部数据」——**设备级**破坏性操作（空间列表页入口）。
///
/// 清空本机全部空间与数据：逐个空间的会话各退役一次（best-effort）→ resetLocalData()。
/// 之所以要逐个 token 退役：一个会话只看得到自己那个空间的设备行，客户端手里有全部
/// 空间的 token（Vault），所以"这台设备整体退网"由客户端逐个调，服务端不需要认识
/// device_uid（device_uid 只用于服务端内部认知，见 deviceUid.ts）。
Future<void> confirmResetDevice(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
  required String deviceName,
  required List<String> tokens,
  bool hasPin = false,
}) async {
  if (!context.mounted) return;
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  final ok = await _confirmDestructive(
    context,
    db: database,
    deviceName: deviceName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.resetDeviceTitle,
      message: l10n.resetDeviceMessage,
      confirmLabel: l10n.resetDeviceConfirm,
    ),
  );
  if (!ok) return;
  if (!context.mounted) return;

  // 退役：尽力而为。这一步走网络，放在 dialog pop 之后由外层承担——dialog 内的
  // busy 只覆盖 Argon2 解锁（毫秒级 vs 网络往返秒级），不顺带卡住 UI。
  var allRetired = true;
  final client = api ?? ApiClient(effectiveServer);
  for (final token in tokens) {
    if (token.isEmpty) {
      allRetired = false;
      continue;
    }
    try {
      await client.retireDevice(token);
    } catch (_) {
      allRetired = false;
    }
  }
  if (!context.mounted) return;

  await resetLocalData(database);
  if (!context.mounted) return;
  if (!allRetired) {
    showTopNotice(context, l10n.resetDeviceServerResidualHint);
  }
  // 清到根再进向导：中途的锁屏页/聊天页都不能留在栈上（它们的密钥已失效）
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const SetupPage()),
    (route) => false,
  );
}

/// 重置确认弹窗：输入本机设备名 +（已设时）锁屏码，两道都对才提交。
///
/// 结构仿对话页的锁屏码弹窗（`chat_page._SetLockDialog`）：说明小字 + 输入框 +
/// 行内红字报错 + 忙碌时禁用提交。错误一律在弹窗内红字报出，不叠第二个弹窗
/// （老板 2026-09-15：两个叠着累赘）。
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
