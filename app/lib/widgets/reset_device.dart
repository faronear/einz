import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../data/local_reset.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';
import '../setup_page.dart';
import '../widgets/top_notice.dart';

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
///
/// **闸门**（老板 2026-09-21 定稿，与 TUI 的 `/reset` 同一套）：
/// ① 手动输入本机设备名（确认清的是这台，挡误触）；② 本机锁屏码（已设才验）。
/// 两者都**离线**可完成——刻意不校验空间口令：那是**共享**给伴侣的加入凭证，不该获得
/// 销毁我这台设备的权力；而校验它必须联网，会让"本机身份属于一台已经连不上的服务器"
/// 这个最常见的重置场景直接自锁（详情见 `server/src/devices.ts` 的 retireDevice）。
///
/// 服务端退役（POST /devices/retire）在闸门通过之后、清本地数据之前尽力而为：
/// 失败也照清，只是如实告知"服务端可能还留有这台设备的记录"。顺序不能反——token
/// 就在本地 store 里，清完就再也没有调用它的凭证了。
Future<void> confirmResetDevice(BuildContext context,
    {LocalDatabase? db,
    ApiClient? api,
    required String deviceName,
    required String token,
    bool hasPin = false}) async {
  if (!context.mounted) return;
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  // 设备名是确认的凭据之一：取不到（空）就没得核对，先把名字补齐再说
  if (deviceName.trim().isEmpty) {
    showTopNotice(context, l10n.resetDeviceNameMissing);
    return;
  }
  final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _ResetDeviceDialog(
          db: database,
          deviceName: deviceName.trim(),
          hasPin: hasPin,
        ),
      ) ??
      false;
  if (!ok) return;
  if (!context.mounted) return;

  // 退役：尽力而为。这一步走网络，放在 dialog pop 之后由外层承担——dialog 内的
  // busy 只覆盖 Argon2 解锁（毫秒级 vs 网络往返秒级），不顺带卡住 UI。
  var retired = true;
  if (token.isNotEmpty) {
    try {
      await (api ?? ApiClient(effectiveServer)).retireDevice(token);
    } catch (_) {
      retired = false;
    }
  } else {
    retired = false; // 没有会话凭证（极端场景）：跳过退役
  }
  if (!context.mounted) return;

  await resetLocalData(database);
  if (!context.mounted) return;
  if (!retired) {
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
class _ResetDeviceDialog extends StatefulWidget {
  const _ResetDeviceDialog({
    required this.db,
    required this.deviceName,
    required this.hasPin,
  });

  final LocalDatabase db;
  final String deviceName;
  final bool hasPin;

  @override
  State<_ResetDeviceDialog> createState() => _ResetDeviceDialogState();
}

class _ResetDeviceDialogState extends State<_ResetDeviceDialog> {
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
      title: Text(l10n.resetDeviceTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.resetDeviceMessage,
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
          child: Text(l10n.resetDeviceConfirm),
        ),
      ],
    );
  }
}
