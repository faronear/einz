import 'dart:async';

import 'package:flutter/foundation.dart';

import 'server_config.dart';

/// 启动选路阶段（只用于启动这一次；运行期断线归 ServerFailover）。
enum ServerPhase {
  /// 还没开始（或开发覆盖，不需要选）。
  idle,

  /// 正在探候选。
  probing,

  /// 已确定一个可达入口（或当前入口就是可达的）。
  ready,

  /// 候选全不通：界面照常进，地址保持临时值，等网络恢复/运行期换入口。
  unreachable,
}

/// 冷启动选路（2026-10-29 第 3A 层）。
///
/// 背景：main() 以前 await resolveServer() 才 runApp()——网络差时原生启动
/// 画面会卡十几秒。现在 main() 先给一个临时值 kFallbackServer 立即出界面，
/// 这里在后台并发探候选，选到更合适的入口就 applyEffectiveServer 广播：
///
/// - **只跑一次**：启动选路不是连接管理器；进聊天页后的断线恢复归 ServerFailover。
/// - **不阻塞进入**：全不通也只标 ServerPhase.unreachable，聊天页照常离线可读。
/// - **人为覆盖不参与**：--server / 编译期 dart-define 直接跳过。
/// - **不覆盖更新的选择**：探测期间若 ServerFailover 已经换过地址（revision 变了），
///   丢弃本次结果，避免旧结果把新入口顶回去。
class ServerBootstrap {
  factory ServerBootstrap({
    Future<ServerHealth> Function(String server)? probe,
  }) =>
      ServerBootstrap._(probe);

  ServerBootstrap._(this._probe);

  /// 全局单例（生产用；测试可 new 一个独立实例）。
  static final ServerBootstrap instance = ServerBootstrap();

  final Future<ServerHealth> Function(String server)? _probe;

  /// 启动选路阶段（3A 没有 UI 消费；留给 3B 的锁屏提示/About 用）。
  final ValueNotifier<ServerPhase> phase =
      ValueNotifier<ServerPhase>(ServerPhase.idle);

  bool _started = false;

  bool get enabled => !serverOverrideActive && !isDevServer;

  Future<void> start() async {
    if (_started || !enabled) return;
    _started = true;
    final probeFn = _probe ?? probeServer;
    final epoch = serverRevision.value;
    phase.value = ServerPhase.probing;
    try {
      final before = effectiveServer;
      // 并发探候选：**谁先 200 用谁**。不能只探当前临时值——海外用户可能
      // 更适合 tic.cc，只有全量并发才能按实际网络选到最快入口。
      final picked =
          await resolveServer(null, probe: probeFn, fallback: before);
      if (serverRevision.value != epoch) {
        // 期间别的路径已经换过地址（ServerFailover）：本次结果作废，
        // 但"已经有人选好了"，阶段标 ready，不要永远停在 probing。
        phase.value = ServerPhase.ready;
        return;
      }
      if (picked != before) {
        applyEffectiveServer(picked);
        phase.value = ServerPhase.ready;
        return;
      }
      // picked == before：要么当前就是最快可达入口，要么全部不通——补探一次区分。
      final current = await probeFn(picked);
      if (serverRevision.value != epoch) {
        phase.value = ServerPhase.ready;
        return;
      }
      phase.value = current.ok ? ServerPhase.ready : ServerPhase.unreachable;
    } catch (_) {
      // 选路失败不影响进入；保持临时地址，聊天页照常离线可读。
      if (serverRevision.value == epoch) {
        phase.value = ServerPhase.unreachable;
      }
    }
  }

  /// 测试隔离。
  @visibleForTesting
  void reset() {
    _started = false;
    phase.value = ServerPhase.idle;
  }
}
