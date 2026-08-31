import 'package:flutter/foundation.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

/// WS 实时服务：封装 shared [WsClient]（连接 + 指数退避重连），
/// 事件回调 + 连接状态通知（chat_page 据此切换轮询策略）。
/// [reauth]：session 过期（WS 4401）时自动重新认证的回调（返回新 token），
/// 供 WsClient.onUnauthorized 续期后立即重连——24h 会话过期无感恢复。
class WsRealtimeService {
  WsRealtimeService({required this.server, required String token, this.reauth}) : _token = token;

  final String server;
  String _token;

  /// 401（session 过期）时自动重新认证的回调（由上层注入：setup_page 的
  /// challenge-response 流程），返回新 token 供 [updateToken] 后重连。
  final Future<String> Function()? reauth;

  String get token => _token;

  /// 更新连接 token（重新认证后调用，供下一次重连使用）。
  void updateToken(String newToken) {
    _token = newToken;
  }

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
      token: _token,
      onUnauthorized: () async {
        // session 过期（4401）：自动重新认证并更新 token，随后 WsClient 立即重连
        final fresh = await reauth?.call();
        if (fresh != null) updateToken(fresh);
      },
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
