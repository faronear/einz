import 'package:flutter/foundation.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

/// WS 实时服务：封装 shared [WsClient]（连接 + 指数退避重连），
/// 事件回调 + 连接状态通知（chat_page 据此切换轮询策略）。
class WsRealtimeService {
  WsRealtimeService({required this.server, required this.token});

  final String server;
  final String token;

  WsClient? _client;

  /// WS 是否在线（chat_page 监听：在线 → 轮询降频兜底；离线 → 恢复高频轮询）。
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// 新消息到达回调（WS 在线时 chat_page 收到即增量刷新，无需等轮询）。
  void Function()? onMessageNew;

  /// 本设备被撤销回调（Server 广播 device.revoked——App 应清理本地数据并强制登出）。
  void Function()? onDeviceRevoked;

  /// 建立连接（自动重连直到 [stop]）。
  void start({void Function()? onMessageNew, void Function()? onDeviceRevoked}) {
    this.onMessageNew = onMessageNew;
    this.onDeviceRevoked = onDeviceRevoked;
    _client = WsClient(
      server: server,
      token: token,
      onEvent: (e) {
        if (e is WsMessageNewEvent) this.onMessageNew?.call();
        if (e is WsDeviceRevokedEvent) this.onDeviceRevoked?.call();
      },
      onStatus: (s) => connected.value = s == WsStatus.connected,
    )..start();
  }

  /// 停止连接。
  Future<void> stop() async {
    await _client?.stop();
    _client = null;
    connected.value = false;
  }
}
