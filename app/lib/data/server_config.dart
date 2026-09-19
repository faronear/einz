import 'dart:convert';
import 'dart:io';

/// 服务器地址层（三层，见 docs/SERVER_SETTINGS.md）。
///
/// 地址**只服务于两件事**：① 开发时临时指向开发服务器；② 出厂域名的容灾冗余。
/// 它不是最终用户可配置项（老板 2026-09-19 决策）——所以：
///
/// - **不进任何持久层**：不写 `app_state`，也不写锁包（`AppLockPayload`）。锁包解锁
///   前读不到，地址存进去就会出现"锁屏页显示的和解锁后实际连的不一致"（这正是
///   `AboutPage.isLocked` 那条附注存在的原因，地址同源后它一并删除）。
/// - **每次启动算一次**：`main()` 里定好存进 [effectiveServer]，之后全程只读。页面
///   之间不再层层透传地址（原先 18 处构造函数参数），所有页面读的是同一个变量。
///
/// 三层优先级：
/// 1. 运行时 `--server <地址>`（桌面端启动参数）——本次启动覆盖，仅本次生效；
/// 2. 编译期 [kEinzServer]——`flutter run/build --dart-define-from-file` 覆盖
///    （本机 `localConfig.*.json`，gitignore），开发指向 localhost 用；
/// 3. 出厂域名 [kFactoryServer]——以上都没有时的硬编码托底。
///
/// ⚠ 发布包绝不带 `--dart-define-from-file`（会把 localhost 烘进产物，且无救回
/// 手段）：正式打包一律走 package.json 里的 release 脚本，它们都不传该参数。
///
/// **扩展提示**：将来若要支持用户自建服务器，地址要变回持久数据（放 `app_state`，
/// 不要放锁包），且"换服务器"不只是改地址——`spaceId`/`token`/设备密钥对全是那台
/// 服务器上的身份，换服务器 = 清库 + 重新入网。详见 docs/SERVER_SETTINGS.md。
const String kEinzServer =
    String.fromEnvironment('kEinzServer', defaultValue: kFactoryServer);

/// 出厂域名（未被任何覆盖时使用）：产品部署域名固定。
const String kFactoryServer = 'https://einz.tic.cc';

/// 本次进程生效的服务器地址：`main()` 里按 `--server` 覆盖定一次，之后只读。
///
/// **给默认值而非 late**：单元测试不走 `main()`，late 未初始化会直接崩。
String effectiveServer = kEinzServer;

/// 当前地址是否**不是**出厂域名（开发覆盖，或将来连上备用域名）。
///
/// 关于页据此标注——开发包一眼可辨，避免误把连着 localhost 的包当正式包。
bool get isNonFactoryServer => effectiveServer != kFactoryServer;

/// 快速健康探测（GET {server}/health，3s 超时）。
///
/// Multiverse：返回 (能连, 协议版本, 能力清单)——/health 不返回全局 person 表
/// （PROTOCOL_MULTIVERSE.md §4.1）；协议版本用于旧服务器提示（不支持 spaces 的
/// 旧 Server 明确升级提示，§8.1）。
Future<(bool, String, List<String>)> probeServer(String server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$server/health'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) return (false, '', const <String>[]);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final pv = json['protocol_version'] as String? ?? '';
    final caps = (json['capabilities'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList();
    return (true, pv, caps);
  } catch (_) {
    return (false, '', const <String>[]);
  } finally {
    client.close(force: true);
  }
}
