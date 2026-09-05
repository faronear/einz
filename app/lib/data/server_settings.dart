import 'dart:convert';
import 'dart:io';

import 'local_database.dart';

/// 默认服务器地址（产品部署域名固定）。
const String kEinzServer = 'https://einz.tic.cc';

/// 服务器地址设置（存本设备 app_state，key='server'）。
///
/// 降低小白负担：默认 einz.tic.cc 能连时全程零打扰；用户手动改过的地址
/// 持久化到本设备，下次启动优先使用，直到连不上才需要重新设置。
class ServerSettings {
  ServerSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'server';

  /// 当前服务器地址：持久化值优先，无则默认 einz.tic.cc。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    final v = row?.value;
    return (v == null || v.isEmpty) ? kEinzServer : v;
  }

  /// 保存服务器地址。
  Future<void> save(String server) async {
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _kKey, value: server));
  }

  /// 快速健康探测（GET {server}/health，3s 超时）。
  /// 返回 (能连, person 名称表)——person 名称表为空 = 服务器还没有任何用户
  /// （首设备场景）；非空 = 已有用户（后续设备场景）。对齐 TUI _probeServer。
  static Future<(bool, Map<String, String>)> probe(String server) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse('$server/health'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return (false, <String, String>{});
      final json = jsonDecode(body) as Map<String, dynamic>;
      final raw = json['person_names'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final names = <String, String>{for (final e in raw.entries) e.key: e.value as String};
      return (true, names);
    } catch (_) {
      return (false, <String, String>{});
    } finally {
      client.close(force: true);
    }
  }

  /// 探测并用 JSON 展示状态（调试/测试辅助）。
  static String statusText(bool ok) => ok ? 'ok' : 'unreachable';
}
