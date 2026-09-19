import 'dart:convert';

import 'package:flutter/material.dart';

import 'brand_logo.dart';
import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/launch_args.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'data/server_config.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';

/// Einz 移动端（及桌面端）入口。
///
/// 启动流程：定好本次生效的服务器地址 → 检查是否已设置启动锁 → 已设置进锁屏页
/// （PIN 解密 Space Key 包），未设置进一次性配置页（认证后设置 PIN）。
///
/// 桌面端支持一个启动参数：`--server <地址>`（`open -a Einz --args
/// --server https://host`）。它覆盖本次启动使用的服务器地址，**仅本次生效**，
/// 下次不带参数启动即回到编译期值/出厂域名（地址从不落盘，见
/// `data/server_config.dart`）。
Future<void> main() async {
  // 必须先初始化 services 绑定再读参数：平台通道依赖它，未初始化时
  // readLaunchArgs 的桥调用会抛错，--server 永远收不到。
  WidgetsFlutterBinding.ensureInitialized();
  // 本次生效地址定一次，之后全程只读（页面不再层层透传，锁屏/解锁同源）。
  final args = await readLaunchArgs();
  effectiveServer = await resolveServer(parseServerArg(args));
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
    final settings = LocaleSettings(LocalDatabase.shared);
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
          // 新 Logo（粉蓝图标）里的天蓝作种子：派生 primary 保持深蓝，交互对比达标
          seedColor: const Color(0xFF3BAFFD),
          brightness: Brightness.light,
        ).copyWith(
          // 粉蓝主色调：叠加 Logo 的粉系强调 + 浅粉表面，主操作色仍为深蓝
          secondary: const Color(0xFFD6529C), // 粉强调（图标粉环同系）
          onSecondary: Colors.white,
          secondaryContainer: const Color(0xFFFDD6ED), // 图标浅粉底
          onSecondaryContainer: const Color(0xFF6E2050),
          tertiary: const Color(0xFF2271F7), // 图标深蓝
          onTertiary: Colors.white,
          tertiaryContainer: const Color(0xFFDCE9F8),
          onTertiaryContainer: const Color(0xFF0B2C54),
          surface: const Color(0xFFFFF8FB), // 浅粉白基调表面
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFFFF4F9),
          surfaceContainer: const Color(0xFFFEF0F6),
          surfaceContainerHigh: const Color(0xFFFCEBF2),
          surfaceContainerHighest: const Color(0xFFFAE4EE),
        ),
        scaffoldBackgroundColor: const Color(0xFFFFF5FA), // 浅粉白纸感背景（图标浅粉底同系）
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF5FA),
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF33415A)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF5C6B82)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE9D5E0)), // 浅粉描边（粉蓝）
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF3BAFFD), width: 1.6), // 图标天蓝
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
  String? _initError; // 本地库查询持续失败（重试耗尽）→ 展示重试页（不误进向导）
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final lock = AppLockService(LocalDatabase.shared);
      // 全新安装（沙盒被清过）就清掉上一次安装残留的安全存储条目——语义 = 卸载即重置
      // （安全存储条目活过卸载，drift 不会；老板 2026-09-14 决策）。必须在读
      // isSetup/loadPlain **之前**，否则残留的明文包会把人直接拖进聊天。
      await lock.ensureFreshInstall();
      final hasLock = await lock.isSetup;
      // 无锁包时读明文配置（跳过 PIN 的无锁场景：下次启动直接进聊天）
      final plain = hasLock ? null : await lock.loadPlain();
      if (!mounted) return;
      setState(() {
        _hasLock = hasLock;
        _plain = plain;
        _initError = null;
      });
    } catch (e) {
      // 本地锁查询失败（如 SQLite 锁竞争/初始化竞态——热重启、异常退出后偶发）。
      // 不能降级为"未配置"进设置向导：数据仍在，向导会让用户误以为设备被清空
      // （且重走向导会重复登记设备）。改为短暂延迟后自动重试；重试耗尽仍失败
      // 则展示"重试"错误页（保留数据，不丢配置）。
      debugPrint('StartupGate 锁状态查询失败（第 ${_retryCount + 1} 次）: $e');
      if (!mounted) return;
      if (_retryCount < 4) {
        _retryCount++;
        await Future<void>.delayed(const Duration(seconds: 1));
        if (mounted) _check();
      } else {
        setState(() => _initError = AppLocalizations.of(context)!.startupInitFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasLock == null) {
      if (_initError != null) {
        // 本地库持续失败：展示重试页（不误进向导——配置未丢失）
        final l10n = AppLocalizations.of(context)!;
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 56),
                  const SizedBox(height: 12),
                  Text(_initError!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _initError = null;
                        _retryCount = 0;
                      });
                      _check();
                    },
                    child: Text(l10n.startupInitRetry),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return Scaffold(
        // 启动加载：旋转 Logo 与检测页同款布局（上半部、96px、无文字）——
        // 原生启动屏 → StartupGate → 检测页全程定格，无尺寸/位置跳变
        // （老板要求 2026-09-09：开屏就确定显示的位置）
        body: Container(
          // 渐变容器必须撑满全屏：Scaffold body 是宽松约束，Container 无
          // alignment 时（RenderProxyBox 尺寸 = child 尺寸）会缩到子项
          // Column 宽度 = 96px Logo —— 开屏约 0.5s 只显示左侧一条渐变 +
          // 右侧白底，随后才跳到检测页全屏（2026-09-10 老板反馈复现；
          // 与 setup_page._buildSplashScreen 同款修复，aafad56）
          alignment: Alignment.topCenter,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Spacer(flex: 2),
                SpinningBrandLogo(size: 96),
                Spacer(flex: 3),
              ],
            ),
          ),
        ),
      );
    }
    if (_hasLock!) return const LockPage();
    final plain = _plain;
    if (plain != null) {
      // 无锁但已配置（用户确认跳过 PIN）：直接进聊天，免打扰；
      // 从明文配置恢复设备密钥对 → 注入 reauth（会话过期自动续期）
      final reauth = (plain.publicKeyB64 != null && plain.privateKeyB64 != null)
          ? () => reauthFromPayload(plain)
          : null;
      return ChatPage(
        spaceId: plain.spaceId,
        deviceId: plain.deviceId,
        spaceKey: base64Decode(plain.spaceKeyB64),
        keyVersion: plain.keyVersion,
        token: plain.token ?? '',
        reauth: reauth,
        publicKeyB64: plain.publicKeyB64,
        privateKeyB64: plain.privateKeyB64,
      );
    }
    return const SetupPage();
  }
}


