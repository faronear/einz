import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit;

import 'package:flutter/material.dart';

import 'brand_logo.dart';
import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'l10n/app_localizations.dart';
import 'widgets/top_notice.dart';

/// 锁屏页：输入 PIN 解密 Space Key 包 → 进入聊天页。
/// 连续错误锁定倒计时（恢复码功能已按老板决策删除）。
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
  final _pinFocus = FocusNode(); // 锁屏激活即聚焦（弹键盘待输入，不用先点一下输入框）
  bool _busy = false;
  String? _error;
  int _lockSeconds = 0;
  Timer? _ticker;
  bool _noLock = false; // 未设置 PIN（无锁包）：锁屏不激活

  @override
  void initState() {
    super.initState();
    _lock = AppLockService(widget.db ?? LocalDatabase());
    // 锁屏仅在设置过 PIN（有锁包）时激活：无锁包（向导跳过 PIN 的明文配置）
    // 不显示解锁表单，避免"无法解锁、跳不出去"的死锁
    _lock.isSetup.then((ok) {
      if (mounted && !ok) setState(() => _noLock = true);
    });
    _refreshLockSeconds();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refreshLockSeconds());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshLockSeconds() async {
    final s = await _lock.remainingLockSeconds;
    if (!mounted) return;
    if (s != _lockSeconds) {
      setState(() => _lockSeconds = s);
      if (s == 0) {
        // 连续错误锁定倒计时结束 → 输入框重新可用：自动把焦点交还它
        // （否则还得手动点一下输入框才弹键盘）。焦点只能等重建后再给——
        // 本帧里输入框仍是 enabled:false，requestFocus 会被忽略
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pinFocus.requestFocus();
        });
      }
    }
  }

  void _enterChat(AppLockPayload payload) {
    if (widget.asOverlay) {
      // 覆盖锁屏（聊天中切后台超时返回）：解锁成功 pop 回聊天页，保留消息状态
      Navigator.of(context).pop();
      return;
    }
    // 冷启动锁屏：解锁成功进入聊天页；从锁包恢复设备密钥对 → 注入 reauth
    // （会话过期 401/4401 时 challenge-response 重新签发 token；旧包无密钥 → null）
    final reauth = (payload.publicKeyB64 != null && payload.privateKeyB64 != null)
        ? () => reauthFromPayload(payload)
        : null;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatPage(
        server: payload.server,
        spaceId: payload.spaceId,
        deviceId: payload.deviceId,
        spaceKey: base64Decode(payload.spaceKeyB64),
        keyVersion: payload.keyVersion,
        token: payload.token ?? '',
        escrowUpdatedAt: payload.escrowUpdatedAt,
        reauth: reauth,
        publicKeyB64: payload.publicKeyB64,
        privateKeyB64: payload.privateKeyB64,
      ),
    ));
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

  /// 顶栏 ⋯：语言切换 + 退出应用（与对话页菜单同款布局：标签靠左、
  /// 当前值靠右，标签用 onSurfaceVariant 淡色）。
  Widget _buildMenu(AppLocalizations l10n) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: '菜单 / More',
      onSelected: (value) {
        // 等菜单 Route 完全关闭再动作（避免 MenuRoute/DialogRoute 交叉卸载断言崩溃）
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          if (value == 'locale') _showLocalePicker();
          if (value == 'exit') _showExitAppDialog();
        });
      },
      itemBuilder: (context) {
        // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
        final langCode = Localizations.localeOf(context).languageCode;
        // 行内左侧标签用稍淡色，与右侧当前值文字（默认 onSurface 深色）区分
        final labelStyle =
            TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
        return [
          PopupMenuItem(
            value: 'locale',
            child: Row(
              children: [
                Text(l10n.chatPageMenuLocaleLabel, style: labelStyle),
                const Spacer(),
                Text(kLocaleLabels[langCode] ?? langCode),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'exit',
            child: Text(l10n.chatPageMenuExit, style: labelStyle),
          ),
        ];
      },
    );
  }

  /// 顶栏 🌐：切换界面语言（跟随系统/中文/English，即时生效——
  /// localeNotifier 通知 EinzApp 重建 MaterialApp，锁屏页语言随之刷新）。
  Future<void> _showLocalePicker() async {
    final settings = LocaleSettings(widget.db ?? LocalDatabase());
    final current = await settings.load();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('界面语言 / Language', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final option in kLocaleOptions)
              ListTile(
                title: Text(kLocaleLabels[option]!),
                trailing: option == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await settings.save(picked);
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!));
  }

  /// 退出应用（等价 TUI /exit）：确认后彻底关闭（锁屏页无聊天可回，不回任何页）。
  Future<void> _showExitAppDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageExitTitle),
        content: Text(l10n.chatPageExitMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.chatPageMenuExit)),
        ],
      ),
    );
    if (shouldExit == true) {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 未设置 PIN（无锁包）：锁屏不激活——提示原因，不显示解锁表单
    if (_noLock) {
      return Scaffold(
        appBar: AppBar(
          // 与其他页面一致：Logo 在标题栏左侧 + 标题（页面中间不再放大 Logo）
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(),
              const SizedBox(width: 10),
              Flexible(
                child: Text(l10n.lockPageTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          actions: [_buildMenu(l10n)],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_open, size: 56),
              const SizedBox(height: 12),
              Text(l10n.lockPageNoPinSet,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16)),
            ],
          ),
        ),
      );
    }
    final locked = _lockSeconds > 0;
    return Scaffold(
      appBar: AppBar(
        // 与其他页面一致：Logo 在标题栏左侧 + 标题（页面中间不再放大 Logo）
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(),
            const SizedBox(width: 10),
            Flexible(
              child: Text(l10n.lockPageTitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [_buildMenu(l10n)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.lockPagePinPrompt,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            TextField(
              controller: _pin,
              // 进入锁屏页即聚焦输入框 → 直接弹键盘等待输入（老板要求 2026-09-14：
              // 此前要手动点一下输入框才出键盘）；冷启动锁屏与后台切回覆盖锁屏都生效
              focusNode: _pinFocus,
              autofocus: true,
              obscureText: true,
              enabled: !locked,
              keyboardType: TextInputType.number,
              // 居中 + 大字号 + 字距（老板 2026-09-15）：像输手机验证码那样——
              // PIN 是短数字串，靠左小字既不明显也不好确认位数
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: InputDecoration(
                labelText: locked ? l10n.lockPageLockedSeconds(_lockSeconds) : l10n.lockPagePinLabel,
                border: const OutlineInputBorder(),
                // 居中后左右留白对称（label 仍顶在左上，不影响）
                contentPadding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onSubmitted: (_) => _unlock(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: locked || _busy ? null : _unlock,
              child: Text(l10n.lockPageUnlock),
            ),
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
