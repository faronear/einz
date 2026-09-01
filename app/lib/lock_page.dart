import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:einz_shared/einz_shared.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'l10n/app_localizations.dart';

/// 锁屏页：输入 PIN 解密 Space Key 包 → 进入聊天页。
/// 连续错误锁定倒计时；PIN 丢失可展开"使用恢复码"入口（12 词）。
///
/// [asOverlay]：true = 聊天中切后台超时返回的覆盖锁屏（解锁成功 pop 回聊天页，
/// 保留消息状态）；false = 冷启动锁屏（解锁成功 pushReplacement 进聊天页）。
class LockPage extends StatefulWidget {
  const LockPage({super.key, this.asOverlay = false, this.db});

  final bool asOverlay;

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  late final AppLockService _lock;
  final _pin = TextEditingController();
  final _recovery = TextEditingController();
  bool _showRecovery = false;
  bool _busy = false;
  String? _error;
  int _lockSeconds = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _lock = AppLockService(widget.db ?? LocalDatabase());
    _refreshLockSeconds();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refreshLockSeconds());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _refreshLockSeconds() async {
    final s = await _lock.remainingLockSeconds;
    if (!mounted) return;
    if (s != _lockSeconds) setState(() => _lockSeconds = s);
  }

  void _enterChat(AppLockPayload payload) {
    if (widget.asOverlay) {
      // 覆盖锁屏（聊天中切后台超时返回）：解锁成功 pop 回聊天页，保留消息状态
      Navigator.of(context).pop();
      return;
    }
    // 冷启动锁屏：解锁成功进入聊天页
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatPage(
        server: payload.server,
        spaceId: payload.spaceId,
        deviceId: payload.deviceId,
        spaceKey: base64Decode(payload.spaceKeyB64),
        keyVersion: payload.keyVersion,
        token: payload.token ?? '',
      ),
    ));
  }

  /// rotate 后同步：解锁成功时用最新 Space Key 重传口令托管包
  /// （KEY_ESCROW.md §7，失败静默，下次解锁自动重试）。
  void _syncEscrow(AppLockPayload payload) {
    final pass = payload.escrowPassphrase;
    final token = payload.token;
    if (pass == null || pass.isEmpty || token == null || token.isEmpty) return;
    unawaited(() async {
      try {
        final escrow = KeyEscrowService(ApiClient(payload.server));
        await escrow.upload(
          passphrase: pass,
          spaceKeyB64: payload.spaceKeyB64,
          spaceId: payload.spaceId,
          keyVersion: payload.keyVersion,
          token: token,
        );
      } catch (_) {
        // 忽略：托管不可用不影响聊天（离线/Server 暂不可达）
      }
    }());
  }

  Future<void> _unlock() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = await _lock.unlock(_pin.text);
      if (!mounted) return;
      _syncEscrow(payload); // rotate 后同步：重传口令托管包
      _enterChat(payload);
    } on AppLockLockedException catch (e) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.lockPageTooManyAttempts(e.remainingSeconds));
    } on AppLockException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.lockPageUnlockFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockWithRecovery() async {
    if (_busy || _recovery.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = await _lock.unlockWithRecovery(_recovery.text.trim());
      if (!mounted) return;
      _syncEscrow(payload);
      _enterChat(payload);
    } on AppLockException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.lockPageRecoveryFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locked = _lockSeconds > 0;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.lockPageTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_outline, size: 56),
            const SizedBox(height: 12),
            Text(l10n.lockPagePinPrompt,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            if (!_showRecovery) ...[
              TextField(
                controller: _pin,
                obscureText: true,
                enabled: !locked,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: locked ? l10n.lockPageLockedSeconds(_lockSeconds) : l10n.lockPagePinLabel,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: locked || _busy ? null : _unlock,
                child: Text(l10n.lockPageUnlock),
              ),
              TextButton(
                onPressed: () => setState(() => _showRecovery = true),
                child: Text(l10n.lockPageUseRecovery),
              ),
            ] else ...[
              TextField(
                controller: _recovery,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: l10n.lockPageRecoveryLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _unlockWithRecovery,
                child: Text(l10n.lockPageRecoveryUnlock),
              ),
              TextButton(
                onPressed: () => setState(() => _showRecovery = false),
                child: Text(l10n.lockPageBackToPin),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}
