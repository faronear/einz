import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../l10n/app_localizations.dart';

/// 弹一个「输入锁屏码」对话框：校验通过返回该码，取消返回 null。
///
/// 用途：**新增空间**。新增空间要把新凭证写进**加密锁包**（`addSpace` 必须给 pin），
/// 而弹层/聊天页都刻意不持有 pin（PIN 只存在于锁屏页/启动门/向导）。
/// 所以这一步要用户现输一次——顺带也是一道合理的确认（往锁屏保护的身份里加东西）。
///
/// 校验走 `AppLockService.unlock`：与锁屏同一套 **Argon2id + 防爆破**（连错 5 次锁 30 秒），
/// 不另造一套。
Future<String?> promptLockCode(
  BuildContext context, {
  required LocalDatabase db,
  String? title,
  String? hint,
}) async {
  if (!context.mounted) return null;
  final l10n = AppLocalizations.of(context)!;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _LockCodeDialog(
      db: db,
      title: title ?? l10n.promptLockCodeTitle,
      hint: hint ?? l10n.promptLockCodeHint,
    ),
  );
}

class _LockCodeDialog extends StatefulWidget {
  const _LockCodeDialog({required this.db, required this.title, required this.hint});

  final LocalDatabase db;
  final String title;
  final String hint;

  @override
  State<_LockCodeDialog> createState() => _LockCodeDialogState();
}

class _LockCodeDialogState extends State<_LockCodeDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    final pin = _ctrl.text;
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
      if (!mounted) return;
      Navigator.of(context).pop(pin);
    } on AppLockLockedException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.lockPageTooManyAttempts(e.remainingSeconds);
      });
    } on AppLockException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.verifyPinWrong;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.setPinDialogSetupFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.hint,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.resetDevicePinLabel,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}
