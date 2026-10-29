import 'dart:async';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart' show ApiException;
import 'package:flutter/foundation.dart';

import 'server_config.dart';

/// 运行期自动换入口（2026-10-29）。
///
/// 背景：冷启动探测在所有候选都失败时会兜底到 [kFallbackServer]（2026-10-29
/// 第 1 层之前是 [kPrimaryServer]，它解析到 127.0.0.1、已停用）。有 Vault 的老
/// 用户冷启动直接进聊天页，不经过 SetupPage 的 4s 重选；[effectiveServer]
/// 启动后不再重选——于是网络恢复后 App 仍死磕那个地址，只能重启。这里补上
/// 运行期换入口：
///
/// - 聊天页每次**网络级**同步失败都会调 [check]（有冷却，不会打爆）；
/// - [check] 先探当前地址：**探通就不换**。401/4401 等应用层错误也会走到这里，
///   必须由 /health 区分——不能因为"会话过期"就换服务器；
/// - 当前探不通 → 回候选列表并发重探，换到第一个可达入口；
/// - 全都不通 → 留在原地址（[resolveServer] 的 fallback 传当前地址），等下一轮。
///
/// 不落盘：换入口只影响本进程，重启仍从候选列表重新探测（与
/// docs/SERVER_SETTINGS.md 的"地址每次启动算一次"一致）。
class ServerFailover {
  ServerFailover({this.cooldown = const Duration(seconds: 30)});

  /// 全局单例（生产用；测试可 new 一个独立实例）。
  static final ServerFailover instance = ServerFailover();

  /// 两次检查的最小间隔：聊天页离线时每 3s 一轮，不能每轮都探四个域名。
  final Duration cooldown;

  DateTime? _lastCheckAt;
  bool _checking = false;

  /// 每次真正换入口 +1（ChatPage 监听它重建 REST/WS 客户端）。
  final ValueNotifier<int> switches = ValueNotifier<int>(0);

  /// 最近一次切换（排障/About 可用；无切换为 null）。
  String? lastSwitchFrom;
  String? lastSwitchTo;
  DateTime? lastSwitchAt;

  /// 是否可换：开发覆盖（`--server` / 编译期 dart-define）是人为指定地址，
  /// 不该被候选列表劫持（与 SetupPage._reprobe 同口径）。
  bool get enabled => !serverOverrideActive && !isDevServer;

  /// 检查一次（幂等/单飞/冷却）。
  ///
  /// [probe] 测试注入；生产走 [probeServer]（自带 DoH 兜底）。
  Future<void> check({
    Future<ServerHealth> Function(String server)? probe,
  }) async {
    if (!enabled || _checking) return;
    final now = DateTime.now();
    final last = _lastCheckAt;
    if (last != null && now.difference(last) < cooldown) return;
    _lastCheckAt = now;
    _checking = true;
    final probeFn = probe ?? probeServer;
    try {
      // 先探当前地址：通了说明是应用层错误（401/4401/限流…），不该换入口。
      final current = await probeFn(effectiveServer);
      if (current.ok) return;
      final before = effectiveServer;
      final picked =
          await resolveServer(null, probe: probeFn, fallback: before);
      if (picked == before || !enabled) return;
      if (!applyEffectiveServer(picked)) return;
      lastSwitchFrom = before;
      lastSwitchTo = picked;
      lastSwitchAt = DateTime.now();
      switches.value++;
    } catch (_) {
      // 换入口是后台自愈，任何异常都不能影响聊天主流程；下一轮再试。
    } finally {
      _checking = false;
    }
  }

  /// 测试隔离：清空冷却/切换记录。
  @visibleForTesting
  void reset() {
    _lastCheckAt = null;
    _checking = false;
    lastSwitchFrom = null;
    lastSwitchTo = null;
    lastSwitchAt = null;
    switches.value = 0;
  }
}

/// 是否是**网络级**失败（值得换入口）。业务错误（401/403/404/409/429…）
/// 换到任何一个入口都一样，不能触发换入口。
///
/// ApiClient 对 5xx 抛 [ApiException]（网关 502/503/504 也属于"这个入口此刻
/// 不可用"）；4xx 一律排除。dart:io 的连接/握手/超时异常直接算。
bool isNetworkFailure(Object error) {
  if (error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException ||
      error is HttpException ||
      error is WebSocketException) {
    return true;
  }
  if (error is ApiException) {
    final status = error.httpStatus;
    return status >= 500 || status == 408;
  }
  return false;
}
