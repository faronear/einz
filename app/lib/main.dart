import 'dart:convert';

import 'package:flutter/material.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';

/// Einz 移动端入口。
///
/// 启动流程：检查是否已设置启动锁 → 已设置进锁屏页（PIN 解密 Space Key 包），
/// 未设置进一次性配置页（认证后设置 PIN）。
void main() {
  runApp(const EinzApp());
}

class EinzApp extends StatefulWidget {
  const EinzApp({super.key});

  @override
  State<EinzApp> createState() => _EinzAppState();
}

class _EinzAppState extends State<EinzApp> {
  Locale? _locale; // null = 跟随系统

  @override
  void initState() {
    super.initState();
    _initLocale();
    // 语言切换（聊天页 🌐）即时生效
    localeNotifier.addListener(_onLocaleChanged);
  }

  @override
  void dispose() {
    localeNotifier.removeListener(_onLocaleChanged);
    super.dispose();
  }

  void _onLocaleChanged() {
    _initLocale();
  }

  Future<void> _initLocale() async {
    final settings = LocaleSettings(LocalDatabase());
    final pref = await settings.load();
    if (!mounted) return;
    setState(() {
      _locale = pref == 'system' ? null : Locale(pref);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Einz',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE07856), // 陶土橙：优雅文艺的暖色调（Between 式，克制的醒目）
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFFBF7F2), // 暖白纸感背景
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFBF7F2),
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF3E3630)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6E6259)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE3D9D0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE07856), width: 1.6),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(96, 50),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      // l10n：中英文资源 + 跟随系统/手动覆盖（locale=null 时跟随系统）
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: _locale,
      home: const StartupGate(),
    );
  }
}

/// 启动门：三分支——有锁包 → 锁屏页；无锁但有明文配置（跳过 PIN）→ 直接进聊天；
/// 都无 → 设置页。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool? _hasLock; // 有 PIN 加密锁包
  AppLockPayload? _plain; // 无锁配置（跳过 PIN 的明文 payload）

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final lock = AppLockService(LocalDatabase());
      final hasLock = await lock.isSetup;
      // 无锁包时读明文配置（跳过 PIN 的无锁场景：下次启动直接进聊天）
      final plain = hasLock ? null : await lock.loadPlain();
      if (!mounted) return;
      setState(() {
        _hasLock = hasLock;
        _plain = plain;
      });
    } catch (e) {
      // 本地锁查询失败（如 SQLite 锁竞争/初始化异常）→ 降级为"未配置"进设置向导，
      // 避免无限停留在启动转环页（main 加载页无错误出口）
      debugPrint('StartupGate 锁状态查询失败，降级为未配置: $e');
      if (!mounted) return;
      setState(() {
        _hasLock = false;
        _plain = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasLock == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_hasLock!) return const LockPage();
    final plain = _plain;
    if (plain != null) {
      // 无锁但已配置（用户确认跳过 PIN）：直接进聊天，免打扰
      return ChatPage(
        server: plain.server,
        spaceId: plain.spaceId,
        deviceId: plain.deviceId,
        spaceKey: base64Decode(plain.spaceKeyB64),
        keyVersion: plain.keyVersion,
        token: plain.token ?? '',
        escrowPassphrase: plain.escrowPassphrase,
      );
    }
    return const SetupPage();
  }
}


