import 'package:flutter/material.dart';

import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';

/// OnlySpace 移动端入口。
///
/// 启动流程：检查是否已设置启动锁 → 已设置进锁屏页（PIN 解密 Space Key 包），
/// 未设置进一次性配置页（认证后设置 PIN）。
void main() {
  runApp(const OnlySpaceApp());
}

class OnlySpaceApp extends StatefulWidget {
  const OnlySpaceApp({super.key});

  @override
  State<OnlySpaceApp> createState() => _OnlySpaceAppState();
}

class _OnlySpaceAppState extends State<OnlySpaceApp> {
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
      title: 'OnlySpace',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      // l10n：中英文资源 + 跟随系统/手动覆盖（locale=null 时跟随系统）
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: _locale,
      home: const StartupGate(),
    );
  }
}

/// 启动门：读取本地锁状态决定首屏（锁屏页 or 设置页）。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool? _locked;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final lock = AppLockService(LocalDatabase());
    final hasLock = await lock.isSetup;
    if (!mounted) return;
    setState(() => _locked = hasLock);
  }

  @override
  Widget build(BuildContext context) {
    if (_locked == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _locked! ? const LockPage() : const SetupPage();
  }
}


