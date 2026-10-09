import 'package:flutter/foundation.dart';
import 'package:einz_shared/einz_shared.dart';

/// WS 实时服务：封装 shared [WsClient]（连接 + 指数退避重连），
/// 事件回调 + 连接状态通知（chat_page 据此切换轮询策略）。
/// [reauth]：session 过期（WS 4401）时自动重新认证的回调（返回新 token），
/// 供 WsClient.onUnauthorized 续期后立即重连——24h 会话过期无感恢复。
class WsRealtimeService {
  WsRealtimeService({required this.server, required this._token, this.reauth});

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

  /// WS 四态（与 TUI「我的灯」同一思维模型，老板 2026-10-08：状态条「我的」灯
  /// 需要区分 灰=未连接 / 黄=连接中 / 绿=已连接 / 红=断线重连）。
  final ValueNotifier<WsStatus> status = ValueNotifier(WsStatus.stopped);

  /// 新消息到达回调（WS 在线时 chat_page 收到即增量刷新，无需等轮询）。
  void Function()? onMessageNew;

  /// 本通道被撤销回调（Server 广播 entrance.revoked——App 应清理本地数据并强制登出）。
  void Function()? onEntranceRevoked;

  /// 对端上下线回调（Server 广播 peer.online/peer.offline——App 实时更新对方在线状态）。
  void Function(WsPeerStatusEvent event)? onPeerStatus;

  /// 口令被重设回调（Server 广播 passphrase.rotated——App 只发通知，不弹窗）。
  void Function(WsPassphraseRotatedEvent event)? onPassphraseRotated;

  /// 对方改名/改通道名回调（Server 广播 profile.updated——App 立即更新对方名）。
  void Function(WsProfileUpdatedEvent event)? onProfileUpdated;

  /// 对方回执更新回调（Server 广播 receipt.updated——已送达/已读高水位）。
  void Function(WsReceiptUpdatedEvent event)? onReceiptUpdated;

  /// 通话信令回调（Server 哑转发 call.*——PROTOCOL.md §8.4）。
  void Function(WsCallEvent event)? onCall;

  /// 新**身份**入网回调（群聊一期 member.joined——来了新人，成员名单要刷新）。
  /// 与 [onPeerStatus] 不同：那是通道上下线，这个是成员数 +1。
  void Function(WsMemberJoinedEvent event)? onMemberJoined;

  /// 建立连接（自动重连直到 [stop]）。
  ///
  /// **幂等**：已有连接（或正在重连）时直接返回，**不建第二条**。
  ///
  /// 为什么必须：服务端 V1 一人一机——同一通道的第二条连接会把第一条以
  /// `duplicate connection`(4408) 踢掉，被踢的那条又自动退避重连、反过来把新的踢掉……
  /// 两条互踢，表现为**在线状态灯红绿秒闪**（2026-09-26 在 macOS 上实测）。
  /// 触发场景是"回到前台重连"：`resumed` 会重复调用，而窗口激活在桌面端很频繁。
  void start({
    void Function()? onMessageNew,
    void Function()? onEntranceRevoked,
    void Function(WsPeerStatusEvent event)? onPeerStatus,
    void Function(WsPassphraseRotatedEvent event)? onPassphraseRotated,
    void Function(WsProfileUpdatedEvent event)? onProfileUpdated,
    void Function(WsReceiptUpdatedEvent event)? onReceiptUpdated,
    void Function(WsCallEvent event)? onCall,
    void Function(WsMemberJoinedEvent event)? onMemberJoined,
  }) {
    if (_client != null) return; // 幂等：已有连接就不再建（见方法头注释）
    this.onMessageNew = onMessageNew;
    this.onEntranceRevoked = onEntranceRevoked;
    this.onPeerStatus = onPeerStatus;
    this.onPassphraseRotated = onPassphraseRotated;
    this.onProfileUpdated = onProfileUpdated;
    this.onReceiptUpdated = onReceiptUpdated;
    this.onCall = onCall;
    this.onMemberJoined = onMemberJoined;
    _client = WsClient(
      server: server,
      token: _token,
      onUnauthorized: () async {
        // session 过期（4401）：自动重新认证并更新 token，随后 WsClient 立即重连
        final fresh = await reauth?.call();
        if (fresh == null) return;
        updateToken(fresh);
        // ★ 关键：WsClient 持有**自己的那一份** token（构造时拷贝），只更新本类的
        //   _token 不管用——它会拿旧 token 重连 → 再被 4401 关掉 → 零延迟死循环
        //   （2026-09-22 实测：把 /auth/challenge 打到 429 RATE_LIMITED，并连累
        //   同一 IP 的邀请加入一起被限流）。CLI 侧一直是对的（chat_core.dart 更新了
        //   wsClient），App 侧漏了这一行。
        _client?.updateToken(fresh);
      },
      onEvent: (e) {
        if (e is WsMessageNewEvent) this.onMessageNew?.call();
        if (e is WsEntranceRevokedEvent) this.onEntranceRevoked?.call();
        if (e is WsPeerStatusEvent) this.onPeerStatus?.call(e);
        if (e is WsPassphraseRotatedEvent) this.onPassphraseRotated?.call(e);
        if (e is WsProfileUpdatedEvent) this.onProfileUpdated?.call(e);
        if (e is WsReceiptUpdatedEvent) this.onReceiptUpdated?.call(e);
        if (e is WsCallEvent) this.onCall?.call(e);
        if (e is WsMemberJoinedEvent) this.onMemberJoined?.call(e);
      },
      onStatus: (s) {
        status.value = s;
        connected.value = s == WsStatus.connected;
      },
    )..start();
  }

  /// 发一个通话信令帧（未连接时静默丢弃——由上层通话状态机的超时/挂断兜底）。
  void sendCall(String type, Map<String, dynamic> payload) {
    _client?.send(type, payload);
  }

  /// 停止连接。
  ///
  /// **先把 `_client` 置空再 await 关闭**：否则在关闭还没跑完时若有人调 [start]，
  /// 幂等判断会看到 `_client != null` 而拒绝重连，于是这条连接**永远不会再连上**
  /// （进后台→回前台的时序里完全可能撞上）。
  Future<void> stop() async {
    final client = _client;
    _client = null;
    connected.value = false;
    await client?.stop();
  }
}
