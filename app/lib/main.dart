import 'package:flutter/material.dart';

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
    try {
      final lock = AppLockService(LocalDatabase());
      final hasLock = await lock.isSetup;
      if (!mounted) return;
      setState(() => _locked = hasLock);
    } catch (e) {
      // 本地锁查询失败（如 SQLite 锁竞争/初始化异常）→ 降级为"未设置锁"进设置向导，
      // 避免无限停留在启动转环页（main 加载页无错误出口）
      debugPrint('StartupGate 锁状态查询失败，降级为未配置: $e');
      if (!mounted) return;
      setState(() => _locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_locked == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _locked! ? const LockPage() : const SetupPage();
  }
}


